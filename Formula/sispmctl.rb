class Sispmctl < Formula
  desc "Control Gembird SIS-PM programmable power outlet strips"
  homepage "https://sispmctl.sourceforge.io/"
  url "https://downloads.sourceforge.net/project/sispmctl/sispmctl/sispmctl-4.8/sispmctl-4.8.tar.gz"
  sha256 "0f8391f7e95cbf1fb96a68686a1dcf1e16747b050ae1b8ff90653c99976068db"
  license "GPL-2.0-or-later"

  livecheck do
    url :stable
  end

  bottle do
    sha256 "81744e45749770c78d2faf4dbbca0acafcfafbcddd13490aa34bc4b0f85376f5" => :catalina
    sha256 "99772ae9b4243338477c550297e5c21bddab9ceaee225c92ed4ea0d5a5877eca" => :mojave
    sha256 "4acb337efca6d3efb2e6b18457ba8e957ae493869f96f230d1555fcb2db354b8" => :high_sierra
  end

  depends_on "pkg-config" => :build
  depends_on "libusb-compat"

  def install
    system "./configure", "--disable-dependency-tracking",
                          "--prefix=#{prefix}"
    system "make", "install"
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/sispmctl -v 2>&1")
  end
end
