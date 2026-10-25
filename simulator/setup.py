# setup.py -- build the native VM extension in place.
#
#   python setup.py build_ext --inplace
#
# Produces _socvm.cp313-win_amd64.pyd next to test_runner.py, which
# rv32i_soc_vm.py picks up automatically (see the tail of that file).
#
# MSVC is required: a CPython extension cannot be built with MinGW (different
# CRT and object layout).  setuptools finds VS 2022 through vswhere.

from setuptools import setup, Extension
import pybind11

setup(
    name="_socvm",
    version="1.0",
    ext_modules=[
        Extension(
            "_socvm",
            sources=[
                "native/socvm.cpp",
                "native/step.cpp",
                "native/blit.cpp",
                "native/bindings.cpp",
            ],
            include_dirs=[pybind11.get_include(), "native"],
            extra_compile_args=["/O2", "/std:c++17", "/EHsc", "/W3", "/wd4996"],
            language="c++",
        )
    ],
)
