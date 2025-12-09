#!/bin/bash

if [[ x"${CMAKE_BUILD_PARALLEL_LEVEL}" == x ]]; then
  n=8
  case "$OSTYPE" in
  linux*)
    n=$(nproc)
    ;;
  darwin*)
    n=$(sysctl -n hw.physicalcpu)
    ;;
  bsd*)
    n=$(sysctl -n hw.ncpu)
    ;;
  esac
  export CMAKE_BUILD_PARALLEL_LEVEL=${n}
fi
