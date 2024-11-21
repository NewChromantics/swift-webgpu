import SwiftUI
import MetalKit

//	macos -> ios aliases to make things a little cleaner to write
#if canImport(UIKit)
import UIKit
#else//macos
import AppKit
public typealias UIView = NSView
public typealias UIColor = NSColor
public typealias UIRect = NSRect
public typealias UIViewRepresentable = NSViewRepresentable
#endif


//	public just so user can use it
public struct RenderError: LocalizedError
{
	let description: String
	
	public init(_ description: String) {
		self.description = description
	}
	
	public var errorDescription: String? {
		description
	}
}



//	callback from low-level (metal)view when its time to render
public protocol ContentRenderer
{
	func Render(contentRect:CGRect,layer:CAMetalLayer)
}


//	persistent interface to webgpu for use with a [WebGpu]View
public class WebGpuRenderer
{
	public var instance : WebGPU.Instance	{	webgpu	}
	var webgpu : WebGPU.Instance = createInstance()
	public var device : Device?
	var windowTextureFormat = TextureFormat.bgra8Unorm

	var initTask : Task<Device,any Error>!
	var deferredRenderErrors : [String] = []
	public var hasDefferredErrors : Bool {	!deferredRenderErrors.isEmpty	}	//	todo: make a better interface for this mid-render
	
	public init()
	{
		initTask = Task
		{
			return try await Init()
		}
	}
	
	public func waitForDevice() async throws -> Device
	{
		return try await initTask.result.get()
	}
	
	func OnDeviceUncapturedError(errorType:ErrorType,errorMessage:String)
	{
		//let error = "\(errorType)/\(errorMessage)"
		let error = errorMessage
		print(error)
		deferredRenderErrors.append(error)
	}
	
	func Init() async throws -> Device
	{
		let adapter = try await webgpu.requestAdapter()
		print("Using adapter: \(adapter.info.device)")
		
		self.device = try await adapter.requestDevice()
		device!.setUncapturedErrorCallback(OnDeviceUncapturedError)
		
		return self.device!
	}
	
	
	public func Render(metalLayer:CAMetalLayer,getCommands:(Device,CommandEncoder,Texture)throws->()) throws
	{
		deferredRenderErrors = []
		
		guard let device else
		{
			throw RenderError("Waiting for device")
		}
		
		let FinalChainSurface = SurfaceSourceMetalLayer(
			layer: Unmanaged.passUnretained(metalLayer).toOpaque()
		)
		
		var surfaceDesc = SurfaceDescriptor()
		surfaceDesc.nextInChain = FinalChainSurface
		let surface = webgpu.createSurface(descriptor: surfaceDesc)
		let surfaceWidth = UInt32(metalLayer.frame.width)
		let surfaceHeight = UInt32(metalLayer.frame.height)
		surface.configure(config: .init(device: device, format: windowTextureFormat, width: surfaceWidth, height: surfaceHeight))
		
		let surfaceTexture = try surface.getCurrentTexture().texture
		let surfaceView = surfaceTexture.createView()
		
		let encoder = device.createCommandEncoder()
		
		//	we want this to just throw, but if there's also errors at this point - we want them too
		do
		{
			//	let caller provide render commands
			try getCommands(device,encoder,surfaceTexture)
		}
		catch let error
		{
			var fullError = error.localizedDescription
			if !deferredRenderErrors.isEmpty
			{
				fullError += "\n"
				fullError += deferredRenderErrors.joined(separator: "\n")
			}
			throw RenderError(fullError)
		}
		
		let commandBuffer = encoder.finish()
		device.queue.submit(commands: [commandBuffer])
		
		surface.present()
		
		if !deferredRenderErrors.isEmpty
		{
			let allErrors = deferredRenderErrors.joined(separator: "\n")
			throw RenderError(allErrors)
		}
	}
}



//	our own abstracted low level view, so we can get access to the layer
public class RenderView : UIView
{
	//var wantsLayer: Bool	{	return true	}
	//	gr: don't seem to need this
	//override var wantsUpdateLayer: Bool { return true	}
	var contentRenderer : ContentRenderer
	var vsync : VSyncer? = nil
	
	var metalLayer : CAMetalLayer

	
#if os(macOS)
	public override var isFlipped: Bool { return true	}	//	gr: this isn't doing anything when in use with webgpu... but true should match ios
#endif
	
	required init?(coder: NSCoder)
	{
		fatalError("init(coder:) has not been implemented")
	}
	
	//	on macos this is CALayer? on ios, it's just CALayer. So this little wrapper makes them the same
	var viewLayer : CALayer?
	{
		return self.layer
	}
	
	init(contentRenderer:ContentRenderer)
	{
		self.contentRenderer = contentRenderer

		self.metalLayer = CAMetalLayer()

		super.init(frame: .zero)
		// Make this a layer-hosting view. First set the layer, then set wantsLayer to true.
		
#if os(macOS)
		wantsLayer = true
		//self.needsLayout = true
#endif

		//	macos only
		//self.layer = CAMetalLayer()

		self.metalLayer.frame = self.bounds
		//	if using sublayer
		viewLayer!.addSublayer(metalLayer)
		vsync = VSyncer(Callback: Render)
	}
	
	
#if os(macOS)
	public override func layout()
	{
		super.layout()
		OnLayoutChanged()
		OnContentsChanged()
	}
#else
	public override func layoutSubviews()
	{
		super.layoutSubviews()
		OnLayoutChanged()
		OnContentsChanged()
	}
#endif
	
	func OnLayoutChanged()
	{
		//	resize sublayer to fit our layer
		//	the change of a sublayer's frame is animation, so disable them in the change
		CATransaction.begin()
		CATransaction.setDisableActions(true)
		self.metalLayer.frame = self.bounds
		CATransaction.commit()
	}
	
	func OnContentsChanged()
	{
		let contentRect = self.bounds
		
		//	render
		contentRenderer.Render(contentRect: contentRect, layer:metalLayer)
	}
	
	//	gr: why did I need @objc...
	@objc public func Render()
	{
		//self.layer?.setNeedsDisplay()
		OnContentsChanged()
	}
	
}

/*
	Actual View for swiftui
*/
public struct WebGpuView : UIViewRepresentable
{
	public typealias UIViewType = RenderView
	public typealias NSViewType = RenderView
	
	var contentRenderer : ContentRenderer
	
	var renderView : RenderView?
	
	public init(contentRenderer:ContentRenderer)
	{
		self.contentRenderer = contentRenderer
		//contentLayer.contentsGravity = .resizeAspect
	}
	
	public func makeUIView(context: Context) -> RenderView
	{
		let view = RenderView(contentRenderer: contentRenderer)
		return view
	}
	
	public func makeNSView(context: Context) -> RenderView
	{
		let view = RenderView(contentRenderer: contentRenderer)
		return view
	}
	
	//	gr: this occurs when the RenderViewRep() is re-initialised, (from uiview redraw)
	//		but the UIView underneath has persisted
	public func updateUIView(_ view: RenderView, context: Context)
	{
		view.contentRenderer = self.contentRenderer
	}
	
	public func updateNSView(_ view: RenderView, context: Context)
	{
		updateUIView(view,context: context)
	}
}



class VSyncer
{
	public var Callback : ()->Void
	
	
	init(Callback:@escaping ()->Void)
	{
		self.Callback = Callback
		
		//	macos 14.0 has CADisplayLink but no way to use it
#if os(macOS)
		let timer = Timer.scheduledTimer(timeInterval: 1.0/60.0, target: self, selector: #selector(OnVsync), userInfo: nil, repeats: true)
		
		//	despite how this looks, this runs the timer on a background thread.
		//	this means when the main thread is blocked (eg, dragging a slider, or scrolling a view)
		//	the timer is still fired, and thus (for example) a metal view still gets rendered [gr: although... is it on another thread?]
		//	https://stackoverflow.com/a/57455910/355753
		RunLoop.main.add(timer, forMode: RunLoop.Mode.common)

#else
		let displayLink = CADisplayLink(target: self, selector: #selector(OnVsync))
		displayLink.add(to: .current, forMode: .default)
#endif
	}
	
	@objc func OnVsync()
	{
		Callback()
	}
}

