cmake_minimum_required(VERSION 3.10)

project(hamma_native VERSION 1.1.0 LANGUAGES CXX C)

# Set C++ standard
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Define the shared library name that LlamaCppLibrary expects: libllama.so / libllama.dylib / llama.dll
add_library(llama SHARED
    llama_ffi_bridge.cpp
)

# Link necessary platform libraries
if(ANDROID)
    target_link_libraries(llama log)
elseif(APPLE)
    # Hardware acceleration for Apple platforms
    target_link_libraries(llama "-framework Metal" "-framework Foundation" "-framework Accelerate")
endif()

# Ensure symbols are visible for FFI
set_target_properties(llama PROPERTIES
    C_VISIBILITY_PRESET default
    CXX_VISIBILITY_PRESET default
    VISIBILITY_INLINES_HIDDEN NO
)
