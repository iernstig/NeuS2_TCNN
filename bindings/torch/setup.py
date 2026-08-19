import os

import torch
from setuptools import setup
from torch.utils.cpp_extension import BuildExtension, CUDAExtension
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
ROOT_DIR = os.path.dirname(os.path.dirname(SCRIPT_DIR))

# Find version of tinycudann by scraping CMakeLists.txt
with open(os.path.join(ROOT_DIR, "CMakeLists.txt"), "r") as cmakelists:
	for line in cmakelists.readlines():
		if line.strip().startswith("VERSION"):
			VERSION = line.split("VERSION")[-1].strip()
			break

print(f"Building PyTorch extension for tiny-cuda-nn version {VERSION}")

ext_modules = []

# Prefer the explicit TCNN_CUDA_ARCHITECTURES environment variable (required
# for cross-compiling on machines with no GPU attached, e.g. Docker builders),
# falling back to auto-detecting the installed GPU via PyTorch.
env_archs = os.environ.get("TCNN_CUDA_ARCHITECTURES", "").strip()
if env_archs:
	compute_capabilities = [int(x) for x in env_archs.replace(";", ",").split(",") if x]
	print(f"Obtained compute capabilities {compute_capabilities} from environment variable TCNN_CUDA_ARCHITECTURES")
elif torch.cuda.is_available():
	major, minor = torch.cuda.get_device_capability()
	compute_capabilities = [major * 10 + minor]
	print(f"Obtained compute capability {compute_capabilities[0]} from PyTorch")
else:
	compute_capabilities = None

if compute_capabilities:
	include_networks = True
	if "--no-networks" in sys.argv:
		include_networks = False
		sys.argv.remove("--no-networks")
		print("Building >> without << neural networks (just the input encodings)")

	if os.name == "nt":
		def find_cl_path():
			import glob
			for edition in ["Enterprise", "Professional", "BuildTools", "Community"]:
				paths = sorted(glob.glob(r"C:\\Program Files (x86)\\Microsoft Visual Studio\\*\\%s\\VC\\Tools\\MSVC\\*\\bin\\Hostx64\\x64" % edition), reverse=True)
				if paths:
					return paths[0]

		if os.system("where cl.exe >nul 2>nul") != 0:
			cl_path = find_cl_path()
			if cl_path is None:
				raise RuntimeError("Could not locate a supported Microsoft Visual C++ installation")
			os.environ["PATH"] += ";" + cl_path

	min_compute_capability = min(compute_capabilities)

	nvcc_flags = [
		"-std=c++17",
		"--extended-lambda",
		"--expt-relaxed-constexpr",
		"-U__CUDA_NO_HALF_OPERATORS__",
		"-U__CUDA_NO_HALF_CONVERSIONS__",
		"-U__CUDA_NO_HALF2_OPERATORS__",
	]
	for cc in compute_capabilities:
		nvcc_flags += [
			f"-gencode=arch=compute_{cc},code=compute_{cc}",
			f"-gencode=arch=compute_{cc},code=sm_{cc}",
		]
	if os.name == "posix":
		cflags = ["-std=c++17"]
		nvcc_flags += [
			"-Xcompiler=-mf16c",
			"-Xcompiler=-Wno-float-conversion",
			"-Xcompiler=-fno-strict-aliasing",
		]
	elif os.name == "nt":
		cflags = ["/std:c++17"]

	print(f"Targeting compute capabilities {compute_capabilities}")

	definitions = [f"-DTCNN_MIN_GPU_ARCH={min_compute_capability}"]
	nvcc_flags += definitions
	cflags += definitions

	# Some containers set this to contain old architectures that won't compile. We only need the ones we're targeting.
	os.environ["TORCH_CUDA_ARCH_LIST"] = ""

	bindings_dir = os.path.dirname(__file__)
	root_dir = os.path.abspath(os.path.join(bindings_dir, "../.."))
	source_files = [
		"tinycudann/bindings.cpp",
		"../../src/cpp_api.cu",
		"../../src/common.cu",
		"../../src/common_device.cu",
		"../../src/encoding.cu",
	]

	if include_networks:
		source_files += [
			"../../src/network.cu",
			"../../src/cutlass_mlp.cu",
		]

		if min_compute_capability >= 70:
			source_files.append("../../src/fully_fused_mlp.cu")
	else:
		nvcc_flags.append("-DTCNN_NO_NETWORKS")
		cflags.append("-DTCNN_NO_NETWORKS")

	ext = CUDAExtension(
		name="tinycudann_bindings._C",
		sources=source_files,
		include_dirs=[
			"%s/include" % root_dir,
			"%s/dependencies" % root_dir,
			"%s/dependencies/cutlass/include" % root_dir,
			"%s/dependencies/cutlass/tools/util/include" % root_dir,
		],
		extra_compile_args={"cxx": cflags, "nvcc": nvcc_flags},
		libraries=["cuda", "cudadevrt", "cudart_static"],
	)
	ext_modules = [ext]
else:
	raise EnvironmentError(
		"Unknown compute capability. Specify the target compute capabilities in the "
		"TCNN_CUDA_ARCHITECTURES environment variable or install PyTorch with the CUDA backend to detect it automatically."
	)

setup(
	name="tinycudann",
	version=VERSION,
	description="tiny-cuda-nn extension for PyTorch",
	long_description="tiny-cuda-nn extension for PyTorch",
	classifiers=[
		"Development Status :: 4 - Beta",
		"Environment :: GPU :: NVIDIA CUDA",
		"License :: BSD 3-Clause",
		"Programming Language :: C++",
		"Programming Language :: CUDA",
		"Programming Language :: Python :: 3 :: Only",
		"Topic :: Multimedia :: Graphics",
		"Topic :: Scientific/Engineering :: Artificial Intelligence",
		"Topic :: Scientific/Engineering :: Image Processing",

	],
	keywords="PyTorch,cutlass,machine learning",
	url="https://github.com/nvlabs/tiny-cuda-nn",
	author="Thomas Müller, Jacob Munkberg, Jon Hasselgren, Or Perel",
	author_email="tmueller@nvidia.com, jmunkberg@nvidia.com, jhasselgren@nvidia.com, operel@nvidia.com",
	maintainer="Thomas Müller",
	maintainer_email="tmueller@nvidia.com",
	download_url=f"https://github.com/nvlabs/tiny-cuda-nn",
	license="BSD 3-Clause \"New\" or \"Revised\" License",
	packages=["tinycudann"],
	install_requires=[],
	include_package_data=True,
	zip_safe=False,
	ext_modules=ext_modules,
	cmdclass={"build_ext": BuildExtension}
)
