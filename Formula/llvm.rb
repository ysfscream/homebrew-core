class Llvm < Formula
  desc "Next-gen compiler infrastructure"
  homepage "https://llvm.org/"
  url "https://github.com/llvm/llvm-project/releases/download/llvmorg-14.0.5/llvm-project-14.0.5.src.tar.xz"
  sha256 "c9d27903ba3883c476a83cd515e36e1e07b0585db55692835de11385d9e3c8fa"
  # The LLVM Project is under the Apache License v2.0 with LLVM Exceptions
  license "Apache-2.0" => { with: "LLVM-exception" }
  head "https://github.com/llvm/llvm-project.git", branch: "main"

  livecheck do
    url :stable
    regex(/^llvmorg[._-]v?(\d+(?:\.\d+)+)$/i)
  end

  bottle do
    sha256 cellar: :any,                 arm64_monterey: "ec2fd8d43fcd0de5bfbffdf63d884c1f521b2ced38ce2e87e06652de35520967"
    sha256 cellar: :any,                 arm64_big_sur:  "3f00231c050cc93c5c49e5f1dda087d264a184a30480d039f40549a6c5913324"
    sha256 cellar: :any,                 monterey:       "fd8252f8acbd5e09112bbc2767a62d0470eaeb65964d437da47f8c49811d4d64"
    sha256 cellar: :any,                 big_sur:        "e78a9788620c9451a2ff789b10a2ed1370c5347f21b42edba2d2d16e5277d486"
    sha256 cellar: :any,                 catalina:       "705f04c87e33cc9e3f26feb2d1721904eea36142a09c2eb752feaa6bbf927c07"
    sha256 cellar: :any_skip_relocation, x86_64_linux:   "3117935ac819ebeda2db10216bab523a4bb6452d340ff3eadbc52b3df6cef710"
  end

  # Clang cannot find system headers if Xcode CLT is not installed
  pour_bottle? only_if: :clt_installed

  keg_only :provided_by_macos

  # https://llvm.org/docs/GettingStarted.html#requirement
  # We intentionally use Make instead of Ninja.
  # See: Homebrew/homebrew-core/issues/35513
  depends_on "cmake" => :build
  depends_on "swig" => :build
  depends_on "python@3.10"

  uses_from_macos "libedit"
  uses_from_macos "libffi", since: :catalina
  uses_from_macos "libxml2"
  uses_from_macos "ncurses"
  uses_from_macos "zlib"

  on_linux do
    depends_on "glibc" if Formula["glibc"].any_version_installed?
    depends_on "pkg-config" => :build
    depends_on "binutils" # needed for gold
    depends_on "elfutils" # openmp requires <gelf.h>
    depends_on "gcc"
  end

  # Fails at building LLDB
  fails_with gcc: "5"

  def install
    projects = %w[
      clang
      clang-tools-extra
      lld
      lldb
      mlir
      polly
    ]
    runtimes = %w[
      compiler-rt
      libcxx
      libcxxabi
      libunwind
    ]
    if OS.mac?
      runtimes << "openmp"
    else
      projects << "openmp"
    end

    python_versions = Formula.names
                             .select { |name| name.start_with? "python@" }
                             .map { |py| py.delete_prefix("python@") }
    site_packages = Language::Python.site_packages("python3").delete_prefix("lib/")

    # Apple's libstdc++ is too old to build LLVM
    ENV.libcxx if ENV.compiler == :clang

    # compiler-rt has some iOS simulator features that require i386 symbols
    # I'm assuming the rest of clang needs support too for 32-bit compilation
    # to work correctly, but if not, perhaps universal binaries could be
    # limited to compiler-rt. llvm makes this somewhat easier because compiler-rt
    # can almost be treated as an entirely different build from llvm.
    ENV.permit_arch_flags

    # we install the lldb Python module into libexec to prevent users from
    # accidentally importing it with a non-Homebrew Python or a Homebrew Python
    # in a non-default prefix. See https://lldb.llvm.org/resources/caveats.html
    args = %W[
      -DLLVM_ENABLE_PROJECTS=#{projects.join(";")}
      -DLLVM_ENABLE_RUNTIMES=#{runtimes.join(";")}
      -DLLVM_POLLY_LINK_INTO_TOOLS=ON
      -DLLVM_BUILD_EXTERNAL_COMPILER_RT=ON
      -DLLVM_LINK_LLVM_DYLIB=ON
      -DLLVM_ENABLE_EH=ON
      -DLLVM_ENABLE_FFI=ON
      -DLLVM_ENABLE_RTTI=ON
      -DLLVM_INCLUDE_DOCS=OFF
      -DLLVM_INCLUDE_TESTS=OFF
      -DLLVM_INSTALL_UTILS=ON
      -DLLVM_ENABLE_Z3_SOLVER=OFF
      -DLLVM_OPTIMIZED_TABLEGEN=ON
      -DLLVM_TARGETS_TO_BUILD=all
      -DLLDB_USE_SYSTEM_DEBUGSERVER=ON
      -DLLDB_ENABLE_PYTHON=ON
      -DLLDB_ENABLE_LUA=OFF
      -DLLDB_ENABLE_LZMA=ON
      -DLLDB_PYTHON_RELATIVE_PATH=libexec/#{site_packages}
      -DLLDB_PYTHON_EXE_RELATIVE_PATH=#{which("python3").relative_path_from(prefix)}
      -DLIBOMP_INSTALL_ALIASES=OFF
      -DCLANG_PYTHON_BINDINGS_VERSIONS=#{python_versions.join(";")}
      -DLLVM_CREATE_XCODE_TOOLCHAIN=OFF
      -DPACKAGE_VENDOR=#{tap.user}
      -DBUG_REPORT_URL=#{tap.issues_url}
      -DCLANG_VENDOR_UTI=org.#{tap.user.downcase}.clang
    ]

    macos_sdk = MacOS.sdk_path_if_needed
    if MacOS.version >= :catalina
      args << "-DFFI_INCLUDE_DIR=#{macos_sdk}/usr/include/ffi"
      args << "-DFFI_LIBRARY_DIR=#{macos_sdk}/usr/lib"
    else
      args << "-DFFI_INCLUDE_DIR=#{Formula["libffi"].opt_include}"
      args << "-DFFI_LIBRARY_DIR=#{Formula["libffi"].opt_lib}"
    end

    # The latest stage builds avoid the shims, and the build
    # will target Penryn unless otherwise specified
    ENV.append_to_cflags "-march=#{Hardware.oldest_cpu}" if Hardware::CPU.intel?

    runtimes_cmake_args = []
    builtins_cmake_args = []

    # Skip the PGO build on HEAD installs or non-bottle source builds
    pgo_build = build.stable? && build.bottle?

    if OS.mac?
      args << "-DLLVM_BUILD_LLVM_C_DYLIB=ON"
      args << "-DLLVM_ENABLE_LIBCXX=ON"
      args << "-DDEFAULT_SYSROOT=#{macos_sdk}" if macos_sdk
      runtimes_cmake_args << "-DCMAKE_INSTALL_RPATH=#{rpath}"
    else
      ENV.append_to_cflags "-fpermissive -Wno-free-nonheap-object"

      args << "-DLLVM_ENABLE_LIBCXX=OFF"
      args << "-DCLANG_DEFAULT_CXX_STDLIB=libstdc++"
      # Enable llvm gold plugin for LTO
      args << "-DLLVM_BINUTILS_INCDIR=#{Formula["binutils"].opt_include}"
      # Parts of Polly fail to correctly build with PIC when being used for DSOs.
      args << "-DCMAKE_POSITION_INDEPENDENT_CODE=ON"
      runtimes_cmake_args += %w[
        -DLLVM_ENABLE_PER_TARGET_RUNTIME_DIR=OFF
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON

        -DLIBCXX_ENABLE_STATIC_ABI_LIBRARY=ON
        -DLIBCXX_STATICALLY_LINK_ABI_IN_SHARED_LIBRARY=OFF
        -DLIBCXX_STATICALLY_LINK_ABI_IN_STATIC_LIBRARY=ON
        -DLIBCXX_USE_COMPILER_RT=ON
        -DLIBCXX_HAS_ATOMIC_LIB=OFF

        -DLIBCXXABI_ENABLE_STATIC_UNWINDER=ON
        -DLIBCXXABI_STATICALLY_LINK_UNWINDER_IN_SHARED_LIBRARY=OFF
        -DLIBCXXABI_STATICALLY_LINK_UNWINDER_IN_STATIC_LIBRARY=ON
        -DLIBCXXABI_USE_COMPILER_RT=ON
        -DLIBCXXABI_USE_LLVM_UNWINDER=ON

        -DLIBUNWIND_USE_COMPILER_RT=ON
        -DCOMPILER_RT_USE_BUILTINS_LIBRARY=ON

        -DSANITIZER_CXX_ABI=libc++
        -DSANITIZER_TEST_CXX=libc++
      ]

      # Prevent compiler-rt from building i386 targets, as this is not portable.
      builtins_cmake_args << "-DCOMPILER_RT_DEFAULT_TARGET_ONLY=ON"
    end

    if ENV.cflags.present?
      args << "-DCMAKE_C_FLAGS=#{ENV.cflags}" unless pgo_build
      runtimes_cmake_args << "-DCMAKE_C_FLAGS=#{ENV.cflags}"
      builtins_cmake_args << "-DCMAKE_C_FLAGS=#{ENV.cflags}"
    end

    if ENV.cxxflags.present?
      args << "-DCMAKE_CXX_FLAGS=#{ENV.cxxflags}" unless pgo_build
      runtimes_cmake_args << "-DCMAKE_CXX_FLAGS=#{ENV.cxxflags}"
      builtins_cmake_args << "-DCMAKE_CXX_FLAGS=#{ENV.cxxflags}"
    end

    args << "-DRUNTIMES_CMAKE_ARGS=#{runtimes_cmake_args.join(";")}" if runtimes_cmake_args.present?
    args << "-DBUILTINS_CMAKE_ARGS=#{builtins_cmake_args.join(";")}" if builtins_cmake_args.present?

    llvmpath = buildpath/"llvm"
    if pgo_build
      # We build LLVM a few times first for optimisations. See
      # https://github.com/Homebrew/homebrew-core/issues/77975

      # PGO build adapted from:
      # https://llvm.org/docs/HowToBuildWithPGO.html#building-clang-with-pgo
      # https://github.com/llvm/llvm-project/blob/33ba8bd2/llvm/utils/collect_and_build_with_pgo.py
      # https://github.com/facebookincubator/BOLT/blob/01f471e7/docs/OptimizingClang.md
      extra_args = [
        "-DLLVM_TARGETS_TO_BUILD=Native",
        "-DLLVM_ENABLE_PROJECTS=clang;compiler-rt;lld",
      ]

      if OS.mac?
        extra_args << "-DLLVM_ENABLE_LIBCXX=ON"
        extra_args << "-DDEFAULT_SYSROOT=#{macos_sdk}" if macos_sdk
      else
        # Make sure CMake doesn't try to pass C++-only flags to C compiler.
        extra_args << "-DCMAKE_C_COMPILER=#{ENV.cc}"
        extra_args << "-DCMAKE_CXX_COMPILER=#{ENV.cxx}"
      end

      cflags = ENV.cflags&.split || []
      cxxflags = ENV.cxxflags&.split || []
      extra_args << "-DCMAKE_C_FLAGS=#{cflags.join(" ")}" unless cflags.empty?
      extra_args << "-DCMAKE_CXX_FLAGS=#{cxxflags.join(" ")}" unless cxxflags.empty?

      # First, build a stage1 compiler. It might be possible to skip this step on macOS
      # and use system Clang instead, but this stage does not take too long, and we want
      # to avoid incompatibilities from generating profile data with a newer Clang than
      # the one we consume the data with.
      mkdir llvmpath/"stage1" do
        system "cmake", "-G", "Unix Makefiles", "..",
                        *extra_args, *std_cmake_args
        system "cmake", "--build", ".", "--target", "clang", "llvm-profdata", "profile"
      end

      # Barring the stage where we generate the profile data, there is no benefit to
      # rebuilding these.
      extra_args << "-DCLANG_TABLEGEN=#{llvmpath}/stage1/bin/clang-tblgen"
      extra_args << "-DLLVM_TABLEGEN=#{llvmpath}/stage1/bin/llvm-tblgen"

      # Our just-built Clang needs a little help finding C++ headers,
      # since we did not build libc++, and the atomic and type_traits
      # headers are not in the SDK on macOS versions before Big Sur.
      if OS.mac? && (MacOS.version <= :catalina && macos_sdk)
        toolchain_path = if MacOS::CLT.installed?
          MacOS::CLT::PKG_PATH
        else
          MacOS::Xcode.toolchain_path
        end

        cxxflags << "-isystem#{toolchain_path}/usr/include/c++/v1"
        cxxflags << "-isystem#{toolchain_path}/usr/include"
        cxxflags << "-isystem#{macos_sdk}/usr/include"

        extra_args.reject! { |s| s["CMAKE_CXX_FLAGS"] }
        extra_args << "-DCMAKE_CXX_FLAGS=#{cxxflags.join(" ")}"
      end

      # On Linux, our just-built Clang needs a little help finding C++ headers,
      # since we did not build libc++, and we are using the libstdc++ headers instead.
      # We also need to make sure it links to libstdc++ for brewed GCC rather than
      # the host GCC which is too old.
      unless OS.mac?
        gcc_version = Formula["gcc"].version.major

        cxxflags << "-isystem#{Formula["gcc"].opt_include}/c++/#{gcc_version}"
        cxxflags << "-isystem#{Formula["gcc"].opt_include}/c++/#{gcc_version}/x86_64-pc-linux-gnu"
        cxxflags << "-nostdinc++"

        extra_args.reject! { |s| s["CMAKE_CXX_FLAGS"] }
        extra_args.reject! { |s| s["CMAKE_C_COMPILER"] }
        extra_args.reject! { |s| s["CMAKE_CXX_COMPILER"] }
        extra_args << "-DCMAKE_CXX_FLAGS=#{cxxflags.join(" ")}"

        libstdcxx_dir = Formula["gcc"].opt_lib/"gcc"/gcc_version
        extra_args << "-DCMAKE_EXE_LINKER_FLAGS=-L#{libstdcxx_dir} -Wl,-rpath,#{libstdcxx_dir}"
        extra_args << "-DCMAKE_SHARED_LINKER_FLAGS=-L#{libstdcxx_dir} -Wl,-rpath,#{libstdcxx_dir}"
      end

      # Next, build an instrumented stage2 compiler
      mkdir llvmpath/"stage2" do
        # LLVM Profile runs out of static counters
        # https://reviews.llvm.org/D92669, https://reviews.llvm.org/D93281
        # Without this, the build produces many warnings of the form
        # LLVM Profile Warning: Unable to track new values: Running out of static counters.
        instrumented_cflags = cflags + ["-Xclang -mllvm -Xclang -vp-counters-per-site=6"]
        instrumented_cxxflags = cxxflags + ["-Xclang -mllvm -Xclang -vp-counters-per-site=6"]
        instrumented_extra_args = extra_args.reject { |s| s[/CMAKE_C(XX)?_FLAGS/] }

        system "cmake", "-G", "Unix Makefiles", "..",
                        "-DCMAKE_C_COMPILER=#{llvmpath}/stage1/bin/clang",
                        "-DCMAKE_CXX_COMPILER=#{llvmpath}/stage1/bin/clang++",
                        "-DLLVM_BUILD_INSTRUMENTED=IR",
                        "-DLLVM_BUILD_RUNTIME=NO",
                        "-DCMAKE_C_FLAGS=#{instrumented_cflags.join(" ")}",
                        "-DCMAKE_CXX_FLAGS=#{instrumented_cxxflags.join(" ")}",
                        *instrumented_extra_args, *std_cmake_args
        system "cmake", "--build", ".", "--target", "clang", "lld"

        # We run some `check-*` targets to increase profiling
        # coverage. These do not need to succeed.
        begin
          system "cmake", "--build", ".", "--target", "check-clang", "check-llvm", "--", "--keep-going"
        rescue RuntimeError
          nil
        end
      end

      # Then, generate the profile data
      mkdir llvmpath/"stage2-profdata" do
        system "cmake", "-G", "Unix Makefiles", "..",
                        "-DCMAKE_C_COMPILER=#{llvmpath}/stage2/bin/clang",
                        "-DCMAKE_CXX_COMPILER=#{llvmpath}/stage2/bin/clang++",
                        *extra_args.reject { |s| s["TABLEGEN"] },
                        *std_cmake_args

        # This build is for profiling, so it is safe to ignore errors.
        begin
          system "cmake", "--build", ".", "--", "--keep-going"
        rescue RuntimeError
          nil
        end
      end

      # Merge the generated profile data
      profpath = llvmpath/"stage2/profiles"
      pgo_profile = profpath/"pgo_profile.prof"
      system llvmpath/"stage1/bin/llvm-profdata", "merge", "-output=#{pgo_profile}", *profpath.glob("*.profraw")

      # Make sure to build with our profiled compiler and use the profile data
      args << "-DCMAKE_C_COMPILER=#{llvmpath}/stage1/bin/clang"
      args << "-DCMAKE_CXX_COMPILER=#{llvmpath}/stage1/bin/clang++"
      args << "-DLLVM_PROFDATA_FILE=#{pgo_profile}"
      # `llvm-tblgen` is an install target, so let's build that.
      args << "-DCLANG_TABLEGEN=#{llvmpath}/stage1/bin/clang-tblgen"

      # Silence some warnings
      cflags << "-Wno-backend-plugin"
      cxxflags << "-Wno-backend-plugin"
      # Make sure stage1 clang can find headers for other formulae on Linux.
      cxxflags << "-isystem#{HOMEBREW_PREFIX}/include" unless OS.mac?

      args << "-DCMAKE_C_FLAGS=#{cflags.join(" ")}"
      args << "-DCMAKE_CXX_FLAGS=#{cxxflags.join(" ")}"

      # Add linker flags on Linux so that stage1 clang can find libstdc++ from brewed GCC and all of the other
      # brewed libraries that need to be linked.
      unless OS.mac?
        ldflags = %W[
          -L#{libstdcxx_dir}
          -Wl,-rpath,#{libstdcxx_dir}
          -L#{HOMEBREW_PREFIX}/lib
          -Wl,-rpath,#{HOMEBREW_PREFIX}/lib
        ]
        args << "-DCMAKE_EXE_LINKER_FLAGS=#{ldflags.join(" ")}"
        args << "-DCMAKE_SHARED_LINKER_FLAGS=#{ldflags.join(" ")}"
      end
    end

    # Now, we can build.
    mkdir llvmpath/"build" do
      system "cmake", "-G", "Unix Makefiles", "..", *(std_cmake_args + args)
      system "cmake", "--build", "."
      system "cmake", "--build", ".", "--target", "install"
    end

    if OS.mac?
      # Get the version from `llvm-config` to get the correct HEAD version too.
      llvm_version = Version.new(Utils.safe_popen_read(bin/"llvm-config", "--version").strip)
      soversion = llvm_version.major.to_s
      soversion << "git" if build.head?

      # Install versioned symlink, or else `llvm-config` doesn't work properly
      lib.install_symlink "libLLVM.dylib" => "libLLVM-#{soversion}.dylib"

      # Install Xcode toolchain. See:
      # https://github.com/llvm/llvm-project/blob/main/llvm/tools/xcode-toolchain/CMakeLists.txt
      # We do this manually in order to avoid:
      #   1. installing duplicates of files in the prefix
      #   2. requiring an existing Xcode installation
      xctoolchain = prefix/"Toolchains/LLVM#{llvm_version}.xctoolchain"
      xcode_version = MacOS::Xcode.installed? ? MacOS::Xcode.version : Version.new(MacOS::Xcode.latest_version)
      compat_version = xcode_version < 8 ? "1" : "2"

      system "/usr/libexec/PlistBuddy", "-c", "Add:CFBundleIdentifier string org.llvm.#{llvm_version}", "Info.plist"
      system "/usr/libexec/PlistBuddy", "-c", "Add:CompatibilityVersion integer #{compat_version}", "Info.plist"
      xctoolchain.install "Info.plist"
      (xctoolchain/"usr").install_symlink [bin, include, lib, libexec, share]
    end

    # Install LLVM Python bindings
    # Clang Python bindings are installed by CMake
    (lib/site_packages).install llvmpath/"bindings/python/llvm"

    # Create symlinks so that the Python bindings can be used with alternative Python versions
    python_versions.each do |py_ver|
      next if py_ver == Language::Python.major_minor_version("python3").to_s

      (lib/"python#{py_ver}/site-packages").install_symlink (lib/site_packages).children
    end

    # Install Vim plugins
    %w[ftdetect ftplugin indent syntax].each do |dir|
      (share/"vim/vimfiles"/dir).install Pathname.glob("*/utils/vim/#{dir}/*.vim")
    end

    # Install Emacs modes
    elisp.install llvmpath.glob("utils/emacs/*.el") + share.glob("clang/*.el")
  end

  def caveats
    <<~EOS
      To use the bundled libc++ please add the following LDFLAGS:
        LDFLAGS="-L#{opt_lib} -Wl,-rpath,#{opt_lib}"
    EOS
  end

  test do
    llvm_version = Version.new(Utils.safe_popen_read(bin/"llvm-config", "--version").strip)
    soversion = llvm_version.major.to_s
    soversion << "git" if head?

    assert_equal version, llvm_version unless head?
    assert_equal prefix.to_s, shell_output("#{bin}/llvm-config --prefix").chomp
    assert_equal "-lLLVM-#{soversion}", shell_output("#{bin}/llvm-config --libs").chomp
    assert_equal (lib/shared_library("libLLVM-#{soversion}")).to_s,
                 shell_output("#{bin}/llvm-config --libfiles").chomp

    (testpath/"omptest.c").write <<~EOS
      #include <stdlib.h>
      #include <stdio.h>
      #include <omp.h>
      int main() {
          #pragma omp parallel num_threads(4)
          {
            printf("Hello from thread %d, nthreads %d\\n", omp_get_thread_num(), omp_get_num_threads());
          }
          return EXIT_SUCCESS;
      }
    EOS

    system "#{bin}/clang", "-L#{lib}", "-fopenmp", "-nobuiltininc",
                           "-I#{lib}/clang/#{llvm_version.major_minor_patch}/include",
                           "omptest.c", "-o", "omptest"
    testresult = shell_output("./omptest")

    sorted_testresult = testresult.split("\n").sort.join("\n")
    expected_result = <<~EOS
      Hello from thread 0, nthreads 4
      Hello from thread 1, nthreads 4
      Hello from thread 2, nthreads 4
      Hello from thread 3, nthreads 4
    EOS
    assert_equal expected_result.strip, sorted_testresult.strip

    (testpath/"test.c").write <<~EOS
      #include <stdio.h>
      int main()
      {
        printf("Hello World!\\n");
        return 0;
      }
    EOS

    (testpath/"test.cpp").write <<~EOS
      #include <iostream>
      int main()
      {
        std::cout << "Hello World!" << std::endl;
        return 0;
      }
    EOS

    # Testing default toolchain and SDK location.
    system "#{bin}/clang++", "-v",
           "-std=c++11", "test.cpp", "-o", "test++"
    assert_includes MachO::Tools.dylibs("test++"), "/usr/lib/libc++.1.dylib" if OS.mac?
    assert_equal "Hello World!", shell_output("./test++").chomp
    system "#{bin}/clang", "-v", "test.c", "-o", "test"
    assert_equal "Hello World!", shell_output("./test").chomp

    # Testing Command Line Tools
    if MacOS::CLT.installed?
      toolchain_path = "/Library/Developer/CommandLineTools"
      system "#{bin}/clang++", "-v",
             "-isysroot", MacOS::CLT.sdk_path,
             "-isystem", "#{toolchain_path}/usr/include/c++/v1",
             "-isystem", "#{toolchain_path}/usr/include",
             "-isystem", "#{MacOS::CLT.sdk_path}/usr/include",
             "-std=c++11", "test.cpp", "-o", "testCLT++"
      assert_includes MachO::Tools.dylibs("testCLT++"), "/usr/lib/libc++.1.dylib"
      assert_equal "Hello World!", shell_output("./testCLT++").chomp
      system "#{bin}/clang", "-v", "test.c", "-o", "testCLT"
      assert_equal "Hello World!", shell_output("./testCLT").chomp
    end

    # Testing Xcode
    if MacOS::Xcode.installed?
      system "#{bin}/clang++", "-v",
             "-isysroot", MacOS::Xcode.sdk_path,
             "-isystem", "#{MacOS::Xcode.toolchain_path}/usr/include/c++/v1",
             "-isystem", "#{MacOS::Xcode.toolchain_path}/usr/include",
             "-isystem", "#{MacOS::Xcode.sdk_path}/usr/include",
             "-std=c++11", "test.cpp", "-o", "testXC++"
      assert_includes MachO::Tools.dylibs("testXC++"), "/usr/lib/libc++.1.dylib"
      assert_equal "Hello World!", shell_output("./testXC++").chomp
      system "#{bin}/clang", "-v",
             "-isysroot", MacOS.sdk_path,
             "test.c", "-o", "testXC"
      assert_equal "Hello World!", shell_output("./testXC").chomp
    end

    # link against installed libc++
    # related to https://github.com/Homebrew/legacy-homebrew/issues/47149
    system "#{bin}/clang++", "-v",
           "-isystem", "#{opt_include}/c++/v1",
           "-std=c++11", "-stdlib=libc++", "test.cpp", "-o", "testlibc++",
           "-rtlib=compiler-rt", "-L#{opt_lib}", "-Wl,-rpath,#{opt_lib}"
    assert_includes (testpath/"testlibc++").dynamically_linked_libraries,
                    (opt_lib/shared_library("libc++", "1")).to_s
    (testpath/"testlibc++").dynamically_linked_libraries.each do |lib|
      refute_match(/libstdc\+\+/, lib)
      refute_match(/libgcc/, lib)
      refute_match(/libatomic/, lib)
    end
    assert_equal "Hello World!", shell_output("./testlibc++").chomp

    if OS.linux?
      # Link installed libc++, libc++abi, and libunwind archives both into
      # a position independent executable (PIE), as well as into a fully
      # position independent (PIC) DSO for things like plugins that export
      # a C-only API but internally use C++.
      #
      # FIXME: It'd be nice to be able to use flags like `-static-libstdc++`
      # together with `-stdlib=libc++` (the latter one we need anyways for
      # headers) to achieve this but those flags don't set up the correct
      # search paths or handle all of the libraries needed by `libc++` when
      # linking statically.

      system "#{bin}/clang++", "-v", "-o", "test_pie_runtimes",
                   "-pie", "-fPIC", "test.cpp", "-L#{opt_lib}",
                   "-stdlib=libc++", "-rtlib=compiler-rt",
                   "-static-libstdc++", "-lpthread", "-ldl"
      assert_equal "Hello World!", shell_output("./test_pie_runtimes").chomp
      (testpath/"test_pie_runtimes").dynamically_linked_libraries.each do |lib|
        refute_match(/lib(std)?c\+\+/, lib)
        refute_match(/libgcc/, lib)
        refute_match(/libatomic/, lib)
        refute_match(/libunwind/, lib)
      end

      (testpath/"test_plugin.cpp").write <<~EOS
        #include <iostream>
        __attribute__((visibility("default")))
        extern "C" void run_plugin() {
          std::cout << "Hello Plugin World!" << std::endl;
        }
      EOS
      (testpath/"test_plugin_main.c").write <<~EOS
        extern void run_plugin();
        int main() {
          run_plugin();
        }
      EOS
      system "#{bin}/clang++", "-v", "-o", "test_plugin.so",
             "-shared", "-fPIC", "test_plugin.cpp", "-L#{opt_lib}",
             "-stdlib=libc++", "-rtlib=compiler-rt",
             "-static-libstdc++", "-lpthread", "-ldl"
      system "#{bin}/clang", "-v",
             "test_plugin_main.c", "-o", "test_plugin_libc++",
             "test_plugin.so", "-Wl,-rpath=#{testpath}", "-rtlib=compiler-rt"
      assert_equal "Hello Plugin World!", shell_output("./test_plugin_libc++").chomp
      (testpath/"test_plugin.so").dynamically_linked_libraries.each do |lib|
        refute_match(/lib(std)?c\+\+/, lib)
        refute_match(/libgcc/, lib)
        refute_match(/libatomic/, lib)
        refute_match(/libunwind/, lib)
      end
    end

    # Testing mlir
    (testpath/"test.mlir").write <<~EOS
      func @bad_branch() {
        br ^missing  // expected-error {{reference to an undefined block}}
      }
    EOS
    system "#{bin}/mlir-opt", "--verify-diagnostics", "test.mlir"

    (testpath/"scanbuildtest.cpp").write <<~EOS
      #include <iostream>
      int main() {
        int *i = new int;
        *i = 1;
        delete i;
        std::cout << *i << std::endl;
        return 0;
      }
    EOS
    assert_includes shell_output("#{bin}/scan-build clang++ scanbuildtest.cpp 2>&1"),
      "warning: Use of memory after it is freed"

    (testpath/"clangformattest.c").write <<~EOS
      int    main() {
          printf("Hello world!"); }
    EOS
    assert_equal "int main() { printf(\"Hello world!\"); }\n",
      shell_output("#{bin}/clang-format -style=google clangformattest.c")

    # Ensure LLVM did not regress output of `llvm-config --system-libs` which for a time
    # was known to output incorrect linker flags; e.g., `-llibxml2.tbd` instead of `-lxml2`.
    # On the other hand, note that a fully qualified path to `dylib` or `tbd` is OK, e.g.,
    # `/usr/local/lib/libxml2.tbd` or `/usr/local/lib/libxml2.dylib`.
    shell_output("#{bin}/llvm-config --system-libs").chomp.strip.split.each do |lib|
      if lib.start_with?("-l")
        assert !lib.end_with?(".tbd"), "expected abs path when lib reported as .tbd"
        assert !lib.end_with?(".dylib"), "expected abs path when lib reported as .dylib"
      else
        p = Pathname.new(lib)
        if p.extname == ".tbd" || p.extname == ".dylib"
          assert p.absolute?, "expected abs path when lib reported as .tbd or .dylib"
        end
      end
    end
  end
end
