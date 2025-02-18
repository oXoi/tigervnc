# FIXME: Since we cannot require CMake 3.17, we cannot used deferred
#        functions, and hence we have to do something similar manually

set_property(GLOBAL PROPERTY LIBTOOL_TARGETS "")

function(libtool_create_control_file target)
  set_property(GLOBAL APPEND PROPERTY LIBTOOL_TARGETS ${target})
endfunction()

function(libtool_generate_control_files)
  get_property(LIBTOOL_TARGETS GLOBAL PROPERTY LIBTOOL_TARGETS)
  foreach(target ${LIBTOOL_TARGETS})
    libtool_generate_control_file(${target})
  endforeach()
endfunction()

function(libtool_generate_control_file _target)
  get_target_property(_target_type ${_target} TYPE)

  message("-- Creating static libtool control file for target ${_target}")
  # No support for shared libraries, as TigerVNC only needs libtool config
  # files for static libraries.
  if("${_target_type}" MATCHES "^[^STATIC_LIBRARY]$")
    message(FATAL_ERROR " -  trying to use libtool_create_control_file for non-static library target.")
  endif()

  #
  # Parse the INTERFACE_LINK_LIBRARIES property to determine which
  # libraries to put into libtool control file as library dependencies,
  # and handle a few corner cases.
  #

  # First we need to split up any internal entries
  set(target_libs "")
  get_property(_target_libs TARGET ${_target}
               PROPERTY INTERFACE_LINK_LIBRARIES)
  foreach(library ${_target_libs})
    if("${library}" MATCHES " ")
      string(REPLACE " " ";" lib_list "${library}")
      list(APPEND target_libs ${lib_list})
    else()
      list(APPEND target_libs "${library}")
    endif()
  endforeach()

  set(STATIC_MODE OFF)
  set(FRAMEWORK OFF)
  get_property(LIBRARY_PATHS TARGET ${_target}
               PROPERTY INTERFACE_LINK_DIRECTORIES)

  foreach(library ${target_libs})
    if(FRAMEWORK)
      set(_target_dependency_libs "${_target_dependency_libs} -framework ${library}")
      set(FRAMEWORK OFF)
      continue()
    elseif(${library} STREQUAL "-framework")
      set(FRAMEWORK ON)
      continue()
    # Assume all entries are shared libs if platform-specific static library
    # extension is not matched.
    elseif(NOT "${library}" MATCHES ".+${CMAKE_STATIC_LIBRARY_SUFFIX}$")
      set(SHARED OFF)
      foreach(suffix ${CMAKE_SHARED_LIBRARY_SUFFIX} ${CMAKE_EXTRA_SHARED_LIBRARY_SUFFIXES})
        if("${library}" MATCHES ".+${suffix}$")
          set(SHARED ON)
          break()
        endif()
      endforeach()

      if(SHARED)
        # Shared library extension matched, so extract the path and library
        # name, then add the result to the libtool dependency libs.  This
        # will always be an absolute path, because that's what CMake uses
        # internally.
        get_filename_component(_shared_lib ${library} NAME_WE)
        get_filename_component(_shared_lib_path ${library} PATH)
        string(REPLACE "lib" "" _shared_lib ${_shared_lib})
        set(_target_dependency_libs "${_target_dependency_libs} -L${_shared_lib_path} -l${_shared_lib}")
      else()
        # No shared library extension matched.  Check whether target is a CMake
        # target.
        if(TARGET ${library})
          # Target is a CMake target, so assume it is a static library and
          # build a reference to it
          get_target_property(library_path ${library} BINARY_DIR)
          set(library ${library_path}/${CMAKE_STATIC_LIBRARY_PREFIX}${library}.la)
          set(_target_dependency_libs "${_target_dependency_libs} ${library}")
        elseif(${library} STREQUAL "-Wl,-Bstatic")
          # All following libraries should be static
          set(STATIC_MODE ON)
        elseif(${library} STREQUAL "-Wl,-Bdynamic")
          # All following libraries should be dynamic
          set(STATIC_MODE OFF)
        elseif(${library} MATCHES "^${CMAKE_LIBRARY_PATH_FLAG}")
          # Library search path
          string(REPLACE ${CMAKE_LIBRARY_PATH_FLAG} "" library ${library})
          list(APPEND LIBRARY_PATHS ${library})
        else()
          # Normal library, so use find_library() to attempt to locate the
          # library in a system directory.

          # Need to remove -l prefix
          if(${library} MATCHES "^${CMAKE_LINK_LIBRARY_FLAG}")
            string(REPLACE ${CMAKE_LINK_LIBRARY_FLAG} "" library ${library})
          endif()

          if(STATIC_MODE)
            set(_library ${CMAKE_STATIC_LIBRARY_PREFIX}${library}${CMAKE_STATIC_LIBRARY_SUFFIX})
            find_library(FL ${_library} PATHS ${LIBRARY_PATHS})
          endif()

          if(NOT FL)
            find_library(FL ${library} PATHS ${LIBRARY_PATHS})
          endif()

          if(FL)
            # Found library. Depending on if it's static or not we might
            # extract the path and library name, then add the
            # result to the libtool dependency libs.
            if("${FL}" MATCHES ".+${CMAKE_STATIC_LIBRARY_SUFFIX}$")
              set(_target_dependency_libs "${_target_dependency_libs} ${FL}")
            else()
              get_filename_component(_shared_lib ${FL} NAME_WE)
              get_filename_component(_shared_lib_path ${FL} PATH)
              string(REPLACE "lib" "" _shared_lib ${_shared_lib})
              set(_target_dependency_libs "${_target_dependency_libs} -L${_shared_lib_path} -l${_shared_lib}")
            endif()
          else()
            message(FATAL_ERROR " - could not find library ${library}")
          endif()
          # Need to clear FL to get new results next loop
          unset(FL CACHE)
        endif()
      endif()
    else()
      # Detected a static library.  Check whether the library pathname is
      # absolute and, if not, use find_library() to get the absolute path.
      get_filename_component(_name ${library} NAME)
      string(REPLACE "${_name}" "" _path ${library})
      if(NOT "${_path}" STREQUAL "")
      	# Pathname is absolute, so add it to the libtool library dependencies
        # as-is.
        set(_target_dependency_libs "${_target_dependency_libs} ${library}")
      else()
        # Pathname is not absolute, so use find_library() to get the absolute
        # path.
        find_library(FL ${library})
        if(FL)
          # Absolute pathname found.  Add it.
          set(_target_dependency_libs "${_target_dependency_libs} ${FL}")
        else()
          message(FATAL_ERROR " - could not find library ${library}")
        endif()
        # Need to clear FL to get new results next loop
        unset(FL CACHE)
      endif()
    endif()
  endforeach()

  get_target_property(_binary_dir ${_target} BINARY_DIR)

  # Write the libtool control file for the static library
  set(_lname ${CMAKE_STATIC_LIBRARY_PREFIX}${_target})
  set(_laname ${_binary_dir}/${_lname}.la)

  file(WRITE ${_laname} "# ${_lname}.la - a libtool library file\n# Generated by ltmain.sh (GNU libtool) 2.2.6b\n")
  file(APPEND ${_laname} "dlname=''\n\n")
  file(APPEND ${_laname} "library_names=''\n\n")
  file(APPEND ${_laname} "old_library='${_lname}${CMAKE_STATIC_LIBRARY_SUFFIX}'\n\n")
  file(APPEND ${_laname} "inherited_linker_flags=''\n\n")
  file(APPEND ${_laname} "dependency_libs=' ${_target_dependency_libs}'\n\n")
  file(APPEND ${_laname} "weak_library_names=''\n\n")
  file(APPEND ${_laname} "current=\n")
  file(APPEND ${_laname} "age=\n")
  file(APPEND ${_laname} "revision=\n\n")
  file(APPEND ${_laname} "installed=no\n\n")
  file(APPEND ${_laname} "shouldnotlink=no\n\n")
  file(APPEND ${_laname} "dlopen=''\n")
  file(APPEND ${_laname} "dlpreopen=''\n\n")
  file(APPEND ${_laname} "libdir='/usr/lib'\n\n")

  # Make sure the timestamp is updated to trigger other make invocations
  set(_lamarker ${_binary_dir}/.${_lname}.la.fresh)
  add_custom_command(OUTPUT "${_lamarker}" DEPENDS ${_target}
    COMMENT "Updating timestamp on ${_lname}.la"
    COMMAND "${CMAKE_COMMAND}" -E touch "${_lamarker}"
    COMMAND "${CMAKE_COMMAND}" -E touch "${_laname}")

  # Add custom command to symlink the static library so that autotools finds
  # the library in .libs.  These are executed after the specified target build.
  set(_libname ${_binary_dir}/.libs/${_lname}${CMAKE_STATIC_LIBRARY_SUFFIX})
  add_custom_command(OUTPUT "${_libname}" DEPENDS ${_target}
    COMMENT "Creating symlink .libs/${_lname}${CMAKE_STATIC_LIBRARY_SUFFIX}"
    COMMAND "${CMAKE_COMMAND}" -E make_directory "${_binary_dir}/.libs"
    COMMAND "${CMAKE_COMMAND}" -E create_symlink ../${_lname}${CMAKE_STATIC_LIBRARY_SUFFIX} "${_libname}")

  add_custom_target(${_target}.la ALL
    DEPENDS "${_lamarker}" "${_libname}")
endfunction()
