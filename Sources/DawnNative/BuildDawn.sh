# exit when any command fails
set -e

cd dawn
mkdir -p out/Release
cd out/Release
#cmake -DBUILD_SHARED_LIBS=0 ../..
cmake -DBUILD_SHARED_LIBS=1 -DCMAKE_OSX_ARCHITECTURES="x86_64;arm64"  ../..
make -j 10 webgpu_dawn
#make dawn_headers # what is this target?

# out/release/src contains the output...
ls ./src/dawn/native/libwebgpu_dawn.dylib
ls -r ./gen

