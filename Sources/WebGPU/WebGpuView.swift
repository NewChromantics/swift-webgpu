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
	var onPreRender : ()->Void
	var onPostRender : ()->Void
	var vsync : VSyncer? = nil
	
	//	dawn is not thread safe, we need to be extremely sure that we don't
	//	try and use the device (render) across multiple threads, so using a
	//	very simple lock to stop multiple threads/tasks rendering at once.
	//	The CADisplayLink and timer "vsync"s should be reusing the same thread...
	let renderLock = NSLock()

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
	
	init(contentRenderer:ContentRenderer,OnPreRender:@escaping()->Void,OnPostRender:@escaping()->Void)
	{
		self.contentRenderer = contentRenderer
		self.onPreRender = OnPreRender
		self.onPostRender = OnPostRender

		self.metalLayer = CAMetalLayer()
		
		//	toggle developer hud at runtime - clear key to hide
		//	gr: this isnt working...
		/*
		if #available(macOS 13.0, *)
		{
			self.metalLayer.developerHUDProperties =
			[
				"mode":"default",
				//"logging": "default"
			]
		}
		 */

		super.init(frame: .zero)
		// Make this a layer-hosting view. First set the layer, then set wantsLayer to true.
		
#if os(macOS)
		wantsLayer = true
		//self.needsLayout = true
#endif

		//	macos only
		//	using this, does not effect direct vs composited
		//self.layer = self.metalLayer

		self.metalLayer.frame = self.bounds
		//	if using sublayer
		if self.layer != metalLayer
		{
			viewLayer!.addSublayer(metalLayer)
		}
		vsync = VSyncer(parentView: self, Callback: Render)
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
		//	gr: the transaction shows up very high on profiler
		if self.metalLayer.frame != self.bounds
		{
			//	resize sublayer to fit our layer
			//	the change of a sublayer's frame is animation, so disable them in the change
			CATransaction.begin()
			CATransaction.setDisableActions(true)
			self.metalLayer.frame = self.bounds
			CATransaction.commit()
		}
	}
	
	
	func OnContentsChanged()
	{
		let contentRect = self.bounds
		
		if !renderLock.try()
		{
			print("dropping frame")
			return
		}
		//	render
		onPreRender()
		contentRenderer.Render(contentRect: contentRect, layer:metalLayer)
		onPostRender()
		renderLock.unlock()
	}
	
	//	gr: why did I need @objc...
	@objc public func Render()
	{
		//self.layer?.setNeedsDisplay()
		OnContentsChanged()
	}
	
}


/*
 Just a small decorative [tag] view
 */
public struct Tag : View
{
	var text : String
	
	var Colour = SwiftUI.Color(NSColor.black.withAlphaComponent(0.4))
	var FontColour = SwiftUI.Color(NSColor.white.withAlphaComponent(0.8))
	var FontSize = CGFloat(10)
	var CornerRadius : CGFloat { FontSize / 2 }
	var Margin : CGFloat { 5 }
	var Padding : CGFloat { FontSize / 2 }
	
	public var body : some View
	{
		ZStack(alignment: .topLeading)
		{
			Text(text)
				.fontWeight(.bold)
				.padding(Padding)
			//.monospaced()	//	macos13
				.font(.system(size:FontSize))
				.background(Colour)	//	macos 12
				.foregroundColor(FontColour)	//	deprecated
				.clipShape(RoundedRectangle(cornerRadius: CornerRadius))
				.padding([.top, .leading], Margin)
		}
	}
}

class FrameCounter
{
	var counter : Int = 0
	var lapFrequency : TimeInterval = 1	//	TimeInterval = seconds
	var lastLapTime : Date? = nil
	var onLap : (CGFloat)->Void
	var timeSinceLap : TimeInterval?
	{
		if let lastLapTime
		{
			return Date().timeIntervalSince(lastLapTime)
		}
		return nil
	}

	init(OnLap:@escaping(CGFloat)->Void)
	{
		self.onLap = OnLap
	}
	
	func Add(increment:Int=1)
	{
		counter += increment
		//	check if it's time to lap
		if let timeSinceLap
		{
			if timeSinceLap > lapFrequency
			{
				Lap(timeSinceLap:timeSinceLap)
			}
		}
		else // first call
		{
			lastLapTime = Date()
		}
	}
	
	func Lap(timeSinceLap:TimeInterval)
	{
		//	report
		var duration = max(0.0001,timeSinceLap)	//	shouldn't be zero, but being safe
		var countPerSec = CGFloat(counter) / duration	//	ideally this is count/1
		
		//	reset (we do this before resetting date in case the callback is super long
		lastLapTime = Date()
		counter = 0
		
		onLap(countPerSec)
	}
}

public class WebGpuViewStats : ObservableObject
{
	@Published public var averageFps : CGFloat = 0
}

/*
	fancy view on top of WebGpuViewDirect so we can add native features, debug tools, like FPS counters
	with the use of swiftui
*/
public struct WebGpuView : View
{
	@State public var showFpsCounter = true
	@State public var stats = WebGpuViewStats()
	var fpsCounter : FrameCounter!
	
	public var contentRenderer : ContentRenderer
	
	public init(contentRenderer: ContentRenderer)
	{
		self.contentRenderer = contentRenderer
		self.label = label
		self.fpsCounter = FrameCounter(OnLap: self.OnFpsLap)
	}
	
	func OnFpsLap(framesPerSecond:CGFloat)
	{
		//	update swiftui state only on main thread
		DispatchQueue.main.async
		{
			self.stats.averageFps = framesPerSecond
			//print("new fps \(framesPerSecond) - \(self.stats.averageFps)")
		}
	}
	
	func OnPreRender()
	{
		//	todo: we can use PreRender & PostRender to measure CPU expense of render
	}
	
	func OnPostRender()
	{
		fpsCounter.Add()
	}

	public var body : some View
	{
		ZStack(alignment: .topLeading)
		{
			WebGpuViewDirect(onPreRender:OnPreRender, onPostRender: OnPostRender, contentRenderer:contentRenderer)
			
			VStack(alignment:.leading,spacing: 0)
			{
				Text("\(fps) fps")
					.fontWeight(.bold)
					Tag(text:label!)
				//.monospaced()	//	macos13
				if showFpsCounter
				{
					let fps = String(format: "%.2f", stats.averageFps)
					Tag(text:"\(fps) fps")
				}
				Spacer()
			}
		}
	}
}


/*
	Minimal View that can be used directly in swiftui as
		WebGpuViewDirect(contentRenderer:contentRenderer)
*/
public struct WebGpuViewDirect : UIViewRepresentable
{
	//@Binding var fps : CGFloat	//	we can use binding variables here
	var onPreRender : ()->Void = {}
	var onPostRender : ()->Void = {}
	
	public typealias UIViewType = RenderView
	public typealias NSViewType = RenderView
	
	var contentRenderer : ContentRenderer
	
	var renderView : RenderView?
	

	public func makeUIView(context: Context) -> RenderView
	{
		let view = RenderView(contentRenderer: contentRenderer,OnPreRender: onPreRender,OnPostRender: onPostRender)
		return view
	}
	
	public func makeNSView(context: Context) -> RenderView
	{
		let view = RenderView(contentRenderer: contentRenderer,OnPreRender: onPreRender,OnPostRender: onPostRender)
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
	
	
	init(parentView:UIView,Callback:@escaping ()->Void)
	{
		self.Callback = Callback
		
		if !initDisplayLink(parentView: parentView)
		{
			initTimer()
		}
	}

	func initDisplayLink(parentView:UIView) -> Bool
	{
#if os(macOS)
		if #available(macOS 14.0, *)
		{
			let displayLink = parentView.displayLink(target: self, selector: #selector(OnVsync))
			displayLink.add(to: .current, forMode: .default)
			return true
		}
#endif
		
#if os(iOS)
		if #available(iOS 3.1, *)
		{
			let displayLink = CADisplayLink(target: self, selector: #selector(OnVsync))
			displayLink.add(to: .current, forMode: .default)
			return true
		}
#endif
		return false
	}
	
	func initTimer()
	{
		let timer = Timer.scheduledTimer(timeInterval: 1.0/60.0, target: self, selector: #selector(OnVsync), userInfo: nil, repeats: true)
		
		//	despite how this looks, this runs the timer on a background thread.
		//	this means when the main thread is blocked (eg, dragging a slider, or scrolling a view)
		//	the timer is still fired, and thus (for example) a metal view still gets rendered [gr: although... is it on another thread?]
		//	https://stackoverflow.com/a/57455910/355753
		//	gr: this does not effect metal hud flicker, nor composite vs direct mode
		RunLoop.main.add(timer, forMode: RunLoop.Mode.common)
	}
	
	@objc func OnVsync()
	{
		Callback()
	}
}

