cmake_minimum_required(VERSION 3.14)
project(runner LANGUAGES CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME} WIN32
  "flutter_window.cpp"
  "main.cpp"
  "utils.cpp"
  "win32_window.cpp"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
  "Runner.rc"
  "runner.exe.manifest"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

# Add preprocessor definitions for the build version.
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION=\"${FLUTTER_VERSION}\"")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MAJOR=${FLUTTER_VERSION_MAJOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MINOR=${FLUTTER_VERSION_MINOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_PATCH=${FLUTTER_VERSION_PATCH}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_BUILD=${FLUTTER_VERSION_BUILD}")

# Disable Windows macros that collide with C++ standard library functions.
target_compile_definitions(${BINARY_NAME} PRIVATE "NOMINMAX")

# Add dependency libraries and include directories. Add any application-specific
# dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter flutter_wrapper_app)
target_link_libraries(${BINARY_NAME} PRIVATE "dwmapi.lib")
target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)

# Vosk native library for Stage 2 offline speech recognition.
#
# The DLLs are not committed. Run the explicit setup script once:
#   powershell -ExecutionPolicy Bypass -File tools/fetch_vosk_windows.ps1
# It extracts them into windows/vosk/, and the build then copies them next to
# the runner executable, which is where DynamicLibrary.open('libvosk.dll')
# looks. When the folder is absent the app still builds and runs: the UI
# reports that the native library is unavailable and typed commands still work.
set(VOSK_WINDOWS_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../vosk")
if(EXISTS "${VOSK_WINDOWS_DIR}/libvosk.dll")
  set(VOSK_RUNTIME_DLLS
    "libvosk.dll"
    "libstdc++-6.dll"
    "libgcc_s_seh-1.dll"
    "libwinpthread-1.dll"
  )
  foreach(VOSK_DLL IN LISTS VOSK_RUNTIME_DLLS)
    if(EXISTS "${VOSK_WINDOWS_DIR}/${VOSK_DLL}")
      add_custom_command(TARGET ${BINARY_NAME} POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy_if_different
          "${VOSK_WINDOWS_DIR}/${VOSK_DLL}"
          "$<TARGET_FILE_DIR:${BINARY_NAME}>/${VOSK_DLL}"
        COMMENT "Copying ${VOSK_DLL} next to the voice testbed executable"
      )
    else()
      message(WARNING
        "Vosk runtime ${VOSK_DLL} is missing from ${VOSK_WINDOWS_DIR}; "
        "speech recognition may fail to load. Re-run tools/fetch_vosk_windows.ps1.")
    endif()
  endforeach()
else()
  message(STATUS
    "Vosk Windows DLLs not found in ${VOSK_WINDOWS_DIR}; speech recognition "
    "will report a native-library error and typed commands will still work. "
    "Run tools/fetch_vosk_windows.ps1 to enable it.")
endif()

# Whisper (whisper.cpp) native libraries — the primary Stage 2 engine.
#
# Same pattern as the Vosk block: the binaries are not committed. Run once:
#   powershell -ExecutionPolicy Bypass -File tools/fetch_whisper_windows.ps1
# It fetches the official whisper.cpp b5454 build into windows/whisper/ and
# copies the ggml-base.en model there as well. The build then copies the
# runtime DLLs next to the runner executable (where DynamicLibrary.open
# looks) and the model into a "models" subfolder next to it.
set(WHISPER_WINDOWS_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../whisper")
if(EXISTS "${WHISPER_WINDOWS_DIR}/whisper.dll")
  set(WHISPER_RUNTIME_DLLS
    "${WHISPER_WINDOWS_DIR}/whisper.dll"
    "${WHISPER_WINDOWS_DIR}/ggml.dll"
    "${WHISPER_WINDOWS_DIR}/ggml-base.dll"
  )
  file(GLOB WHISPER_CPU_DLLS
    "${WHISPER_WINDOWS_DIR}/ggml-cpu-*.dll"
  )
  foreach(WHISPER_DLL IN LISTS WHISPER_RUNTIME_DLLS WHISPER_CPU_DLLS)
    add_custom_command(TARGET ${BINARY_NAME} POST_BUILD
      COMMAND ${CMAKE_COMMAND} -E copy_if_different
        "${WHISPER_DLL}"
        "$<TARGET_FILE_DIR:${BINARY_NAME}>"
      COMMENT "Copying ${WHISPER_DLL} next to the voice testbed executable"
    )
  endforeach()
  # The model is large (~141 MB) and gitignored; when it is present it is
  # copied into models/ next to the executable so a developer build works
  # without an in-app download. Production installs use the app's model
  # manager instead.
  if(EXISTS "${WHISPER_WINDOWS_DIR}/ggml-base.en.bin")
    add_custom_command(TARGET ${BINARY_NAME} POST_BUILD
      COMMAND ${CMAKE_COMMAND} -E make_directory
        "$<TARGET_FILE_DIR:${BINARY_NAME}>/models"
      COMMAND ${CMAKE_COMMAND} -E copy_if_different
        "${WHISPER_WINDOWS_DIR}/ggml-base.en.bin"
        "$<TARGET_FILE_DIR:${BINARY_NAME}>/models/ggml-base.en.bin"
      COMMENT "Copying the Whisper model next to the voice testbed executable"
    )
  endif()
else()
  message(STATUS
    "Whisper Windows DLLs not found in ${WHISPER_WINDOWS_DIR}; speech "
    "recognition will report a native-library error and typed commands will "
    "still work. Run tools/fetch_whisper_windows.ps1 to enable it.")
endif()
