# configure_guarded.cmake -- `cmake -B` that survives its own directory moving.
#
# Added by vibe3d (task 0673); not part of the vendored upstream. See PATCHES.md.
#
#   cmake -DGUARD_SOURCE_DIR=<src> -DGUARD_BUILD_DIR=<bld> \
#         -P configure_guarded.cmake -- <flags passed on to `cmake -B`>
#
# WHY THIS EXISTS
#
# A CMake build directory records the absolute paths it was created for
# (CMAKE_CACHEFILE_DIR, CMAKE_HOME_DIRECTORY). Reach the very same files
# through a different absolute path -- a bind mount, a container, a moved or
# copied checkout -- and CMake refuses to reuse the directory, loudly and
# fatally. That is what broke the nightly: the release job bind-mounts the
# workspace into a container at /src and builds there, over a build directory
# a previous job had created under the runner's own path.
#
# Until task 0662 this could not happen, because these preBuildCommands began
# with `rm -rf .../out`, and a directory that never survives cannot be stale.
# Removing that wipe was right -- it was rebuilding the whole C++ backend for
# a one-line D change -- but it also removed the only thing making the build
# indifferent to its own path. This script restores that property WITHOUT
# restoring the wipe.
#
# HOW
#
# We do not try to predict CMake's verdict; we ask for it. `cmake -B` runs
# exactly as before. Only if it FAILS do we look at the cache, and only if the
# cache names some other directory do we clear it and try once more.
#
# That ordering matters, and a cheaper-looking design is wrong: comparing the
# recorded path against the current one as STRINGS is stricter than CMake
# itself. CMake compares by device+inode, so the same directory reached under
# two visible names is accepted -- measured, task 0673 -- and a string test
# would throw away a perfectly good warm cache there. Here that case never
# reaches the comparison at all, because the configure simply succeeds.
#
# The converse is what makes the check safe: paths equal as strings means the
# same directory means CMake did not refuse for this reason. So when the cache
# does name the current directories, the failure is something else (a missing
# system dependency, say) and we deliberately keep the directory and report.

cmake_minimum_required(VERSION 3.13)

foreach(_required GUARD_SOURCE_DIR GUARD_BUILD_DIR)
  if(NOT DEFINED ${_required} OR "${${_required}}" STREQUAL "")
    message(FATAL_ERROR "configure_guarded.cmake: -D${_required}=<path> is required")
  endif()
endforeach()

# Normalise the way CMake stores paths in the cache: forward slashes, absolute,
# no trailing slash, no `.`/`..` segments. dub hands us a native path, so on
# Windows this is what makes the later comparison meaningful at all.
function(_guard_normalise out_var raw)
  file(TO_CMAKE_PATH "${raw}" _p)
  get_filename_component(_p "${_p}" ABSOLUTE)
  set(${out_var} "${_p}" PARENT_SCOPE)
endfunction()

_guard_normalise(GUARD_SOURCE_DIR "${GUARD_SOURCE_DIR}")
_guard_normalise(GUARD_BUILD_DIR "${GUARD_BUILD_DIR}")

# Everything after the literal `--` is forwarded to `cmake -B` untouched, so
# the build's actual knobs stay visible in dub.json rather than hiding here.
set(_forward "")
set(_seen_separator FALSE)
math(EXPR _last_argv "${CMAKE_ARGC} - 1")
foreach(_i RANGE 0 ${_last_argv})
  set(_arg "${CMAKE_ARGV${_i}}")
  if(_seen_separator)
    list(APPEND _forward "${_arg}")
  elseif(_arg STREQUAL "--")
    set(_seen_separator TRUE)
  endif()
endforeach()

function(_guard_configure result_var)
  execute_process(
    COMMAND "${CMAKE_COMMAND}" -B "${GUARD_BUILD_DIR}" ${_forward} "${GUARD_SOURCE_DIR}"
    RESULT_VARIABLE _rc)
  set(${result_var} "${_rc}" PARENT_SCOPE)
endfunction()

# Read back the two directories the existing cache was created for. Either one
# being absent counts as "does not name our directory": a cache that cannot say
# where it came from cannot be trusted to be reusable, and the only thing we
# ever delete is a regenerable build directory CMake has just refused.
function(_guard_cached_dirs out_build out_source)
  set(${out_build} "" PARENT_SCOPE)
  set(${out_source} "" PARENT_SCOPE)
  set(_cache "${GUARD_BUILD_DIR}/CMakeCache.txt")
  if(NOT EXISTS "${_cache}")
    return()
  endif()
  file(STRINGS "${_cache}" _lines
       REGEX "^CMAKE_(CACHEFILE_DIR|HOME_DIRECTORY):INTERNAL=")
  foreach(_line IN LISTS _lines)
    # STRIP the captured value: a cache written with CRLF would otherwise carry
    # a trailing \r into the path and make every comparison report a move.
    if(_line MATCHES "^CMAKE_CACHEFILE_DIR:INTERNAL=(.*)$")
      string(STRIP "${CMAKE_MATCH_1}" _v)
      set(${out_build} "${_v}" PARENT_SCOPE)
    elseif(_line MATCHES "^CMAKE_HOME_DIRECTORY:INTERNAL=(.*)$")
      string(STRIP "${CMAKE_MATCH_1}" _v)
      set(${out_source} "${_v}" PARENT_SCOPE)
    endif()
  endforeach()
endfunction()

_guard_configure(_rc)
if(_rc EQUAL 0)
  return()
endif()

if(NOT EXISTS "${GUARD_BUILD_DIR}/CMakeCache.txt")
  message(FATAL_ERROR
    "configure_guarded.cmake: configuring ${GUARD_SOURCE_DIR} failed, and "
    "${GUARD_BUILD_DIR} holds no CMake cache -- there is no stale directory to "
    "blame. The CMake error above is the real one.")
endif()

_guard_cached_dirs(_cached_build _cached_source)

# Both are checked, not just the first. A configure that CMake ACCEPTED under a
# second path rewrites CMAKE_CACHEFILE_DIR to the new path but leaves
# CMAKE_HOME_DIRECTORY pointing at the old one (measured, task 0673), so a cache
# can be stale in the source half while the build half looks current.
set(_moved FALSE)
if(NOT "${_cached_build}" STREQUAL "${GUARD_BUILD_DIR}")
  set(_moved TRUE)
endif()
if(NOT "${_cached_source}" STREQUAL "${GUARD_SOURCE_DIR}")
  set(_moved TRUE)
endif()

if(NOT _moved)
  message(FATAL_ERROR
    "configure_guarded.cmake: configuring ${GUARD_SOURCE_DIR} failed, and its "
    "build directory ${GUARD_BUILD_DIR} is NOT stale -- its cache names exactly "
    "these directories, so CMake did not refuse over a path change. The "
    "directory was left intact on purpose; the CMake error above is the real "
    "one. (Delete ${GUARD_BUILD_DIR} by hand if you want to rule it out.)")
endif()

message("configure_guarded.cmake: ${GUARD_BUILD_DIR} was created for a "
        "different location and CMake will not reuse it "
        "(cache says build=[${_cached_build}] source=[${_cached_source}], "
        "we are build=[${GUARD_BUILD_DIR}] source=[${GUARD_SOURCE_DIR}]). "
        "Clearing it and configuring once more.")

file(REMOVE_RECURSE "${GUARD_BUILD_DIR}")

_guard_configure(_rc_retry)
if(NOT _rc_retry EQUAL 0)
  message(FATAL_ERROR
    "configure_guarded.cmake: configuring ${GUARD_SOURCE_DIR} still failed "
    "after clearing the relocated build directory ${GUARD_BUILD_DIR}. The "
    "stale path was not the (only) problem; the CMake error above is the real "
    "one.")
endif()
