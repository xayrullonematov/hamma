# This CMakeLists.txt is intentionally kept minimal.
# hamma_native build has been superseded by llama_cpp_dart which manages its own native dependencies.
# This file is retained to avoid breaking the Android Gradle sync, but no longer compiles custom bridges.

cmake_minimum_required(VERSION 3.10)
project(hamma_native VERSION 1.1.0 LANGUAGES CXX C)
