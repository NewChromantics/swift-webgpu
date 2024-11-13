# exit when any command fails
set -e

# identity of team eg. "A11AA11AA1"
SIGNING_IDENTITY=$1

# path to the macos artifact from google's CI run
# https://github.com/google/dawn/actions/workflows/ci.yml
# expect RELEASE_ROOT/lib and /include dirs inside
# todo: automate this? or make it a param?
#RELEASE_ROOT="Dawn-ecf224df05e711fe7009fbd76840301fb82bde1a-macos-latest-Release"
RELEASE_ROOT="./"

OUTPUT_FILENAME="webgpu_dawn.xcframework"
OUTPUT_PATH="./${OUTPUT_FILENAME}"

# old dylib->framework approach
#MACOS_LIBRARY_PATH="${RELEASE_ROOT}/lib/libwebgpu_dawn.dylib"
#MACOS_HEADER_PATH="${RELEASE_ROOT}/include"

# extra resources we need
DAWN_JSON_PATH="${RELEASE_ROOT}/dawn.json"
PRIVACY_MANIFEST_PATH="${RELEASE_ROOT}/PrivacyInfo.xcprivacy"

MACOS_FRAMEWORK_PATH="${RELEASE_ROOT}/macos/webgpu_dawn.framework"
IOS_FRAMEWORK_PATH="${RELEASE_ROOT}/ios/webgpu_dawn.framework"

# xcodebuild fails if any contents inside already exist, so clean it out
# ||true will continue (not exit 1) if the path doesnt exist
rm -r ${OUTPUT_PATH} || true

cp ${PRIVACY_MANIFEST_PATH} ${MACOS_FRAMEWORK_PATH}/Resources

# ios frameworks dont have a /Resources folder - copy to root
cp ${PRIVACY_MANIFEST_PATH} ${IOS_FRAMEWORK_PATH}

# check state of signing of frameworks
codesign -dv ${MACOS_FRAMEWORK_PATH} || true
codesign -dv ${IOS_FRAMEWORK_PATH} || true	#	will error as it's not signed

#xcodebuild -create-xcframework \
#	-library ${MACOS_LIBRARY_PATH} \
#	-headers ${MACOS_HEADER_PATH}	\
#	-output ${OUTPUT_PATH}

xcodebuild -create-xcframework \
	-framework ${MACOS_FRAMEWORK_PATH} \
	-framework ${IOS_FRAMEWORK_PATH} \
	-output ${OUTPUT_PATH}



# we cannot include arbritary files into an xcframework via normal means, but we can sneak them into the output folder
cp ${DAWN_JSON_PATH} ${OUTPUT_PATH}

# need to sign the xcframework for use in the mac store
#codesign -dv ${OUTPUT_PATH} #  will show is not signed
# https://developer.apple.com/documentation/xcode/creating-a-multi-platform-binary-framework-bundle
codesign --timestamp -s "$SIGNING_IDENTITY" ${OUTPUT_PATH}

