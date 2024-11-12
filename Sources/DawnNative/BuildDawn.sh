# exit when any command fails
set -e

cd dawn
mkdir -p out/Release
cd out/Release

# gr: need shared libs=0 or we get compile errors
cmake -DBUILD_SHARED_LIBS=0 -DCMAKE_SYSTEM_NAME=Darwin -DCMAKE_OSX_ARCHITECTURES="x86_64;arm64"  ../..
make -j 10 webgpu_dawn
#make dawn_headers # what is this target?

# out/release/src contains the output...
ls ./src/dawn/native/libwebgpu_dawn.dylib
ls -r ./gen

# ios
cmake -DBUILD_SHARED_LIBS=1 -DCMAKE_SYSTEM_NAME=iOS ../..
