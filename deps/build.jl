using BinDeps
using Compat

const version = "3.0.1"
const unpacked_dir = "optimpack-$version"

@BinDeps.setup

libs = [
    cobyla = library_dependency("libcobyla")
    bobyqa = library_dependency("libbobyqa")
    newuoa = library_dependency("libnewuoa")
    optimpack = library_dependency("libopk")
]

provides(Sources,
         URI("https://github.com/emmt/OptimPack/releases/download/v$version/optimpack-$version.tar.gz"),
         libs,
         unpacked_dir=unpacked_dir)

prefix = joinpath(BinDeps.depsdir(optimpack), "usr")
srcdir = joinpath(BinDeps.depsdir(optimpack), "src", unpacked_dir)
libdir = joinpath(prefix, "lib")

function dynlibname(name)
    ext = Base.Libdl.dlext
    @compat @static if is_unix()
        return "lib$(name).$(ext)"
    elseif is_windows()
        return "$(name).$(ext)"
    else
        error("unknown architecture")
    end
end

destlib = joinpath(libdir, dynlibname("opk"))

provides(SimpleBuild,
         (@build_steps begin
             GetSources(optimpack)
             CreateDirectory(prefix)
             CreateDirectory(libdir)
             @build_steps begin
                 ChangeDirectory(srcdir)
                 FileRule(destlib,
                          @build_steps begin
                              `./configure --enable-shared --disable-static --prefix="$prefix"`
                              `make`
                              `make install`
                              `ls -l "$libdir"`
                          end)
             end
         end),
         libs)

@BinDeps.install @compat Dict(:libopk => :_libopk,
                              :libcobyla => :_libcobyla,
                              :libbobyqa => :_libbobyqa,
                              :libnewuoa => :_libnewuoa)
