class Go < Formula
  desc "The Go programming language"
  homepage "https://golang.org"

  stable do
    url "https://storage.googleapis.com/golang/go1.8.src.tar.gz"
    mirror "https://fossies.org/linux/misc/go1.8.src.tar.gz"
    version "1.8"
    sha256 "406865f587b44be7092f206d73fc1de252600b79b3cacc587b74b5ef5c623596"

    go_version = version.to_s.split(".")[0..1].join(".")
    resource "gotools" do
      url "https://go.googlesource.com/tools.git",
          :branch => "release-branch.go#{go_version}"
    end
  end

  head do
    url "https://go.googlesource.com/go.git"

    resource "gotools" do
      url "https://go.googlesource.com/tools.git"
    end
  end

  option "without-cgo", "Build without cgo (also disables race detector)"
  option "without-godoc", "godoc will not be installed for you"
  option "without-race", "Build without race detector"

  depends_on :macos => :mountain_lion

  patch :DATA

  # Don't update this unless this version cannot bootstrap the new version.
  resource "gobootstrap" do
    url "https://storage.googleapis.com/golang/go1.7.darwin-amd64.tar.gz"
    version "1.7"
    sha256 "51d905e0b43b3d0ed41aaf23e19001ab4bc3f96c3ca134b48f7892485fc52961"
  end

  def install
    (buildpath/"gobootstrap").install resource("gobootstrap")
    ENV["GOROOT_BOOTSTRAP"] = buildpath/"gobootstrap"

    cd "src" do
      ENV["GOROOT_FINAL"] = libexec
      ENV["GOOS"]         = "darwin"
      ENV["CGO_ENABLED"]  = "0" if build.without?("cgo")
      system "./make.bash", "--no-clean"
    end

    (buildpath/"pkg/obj").rmtree
    rm_rf "gobootstrap" # Bootstrap not required beyond compile.
    libexec.install Dir["*"]
    bin.install_symlink Dir[libexec/"bin/go*"]

    # Race detector only supported on amd64 platforms.
    # https://golang.org/doc/articles/race_detector.html
    if build.with?("cgo") && build.with?("race") && MacOS.prefer_64_bit?
      system bin/"go", "install", "-race", "std"
    end

    if build.with? "godoc"
      ENV.prepend_path "PATH", bin
      ENV["GOPATH"] = buildpath
      (buildpath/"src/golang.org/x/tools").install resource("gotools")

      if build.with? "godoc"
        cd "src/golang.org/x/tools/cmd/godoc/" do
          system "go", "build"
          (libexec/"bin").install "godoc"
        end
        bin.install_symlink libexec/"bin/godoc"
      end
    end
  end

  def caveats; <<-EOS.undent
    A valid GOPATH is required to use the `go get` command.
    If $GOPATH is not specified, $HOME/go will be used by default:
      https://golang.org/doc/code.html#GOPATH

    You may wish to add the GOROOT-based install location to your PATH:
      export PATH=$PATH:#{opt_libexec}/bin
    EOS
  end

  test do
    (testpath/"hello.go").write <<-EOS.undent
    package main

    import "fmt"

    func main() {
        fmt.Println("Hello World")
    }
    EOS
    # Run go fmt check for no errors then run the program.
    # This is a a bare minimum of go working as it uses fmt, build, and run.
    system bin/"go", "fmt", "hello.go"
    assert_equal "Hello World\n", shell_output("#{bin}/go run hello.go")

    if build.with? "godoc"
      assert File.exist?(libexec/"bin/godoc")
      assert File.executable?(libexec/"bin/godoc")
    end

    if build.with? "cgo"
      ENV["GOOS"] = "freebsd"
      system bin/"go", "build", "hello.go"
    end
  end
end
__END__
--- a/VERSION
+++ b/VERSION
@@ -1 +1 @@
-go1.8
\ No newline at end of file
+go1.8-parallelbuilds
\ No newline at end of file

diff --git a/src/cmd/go/build.go b/src/cmd/go/build.go
index 98a6509..9008c43 100644
--- a/src/cmd/go/build.go
+++ b/src/cmd/go/build.go
@@ -733,6 +733,8 @@ type builder struct {
 	exec      sync.Mutex
 	readySema chan bool
 	ready     actionQueue
+
+	tasks chan func()
 }
 
 // An action represents a single action in the action graph.
@@ -1281,6 +1283,7 @@ func (b *builder) do(root *action) {
 	}
 
 	b.readySema = make(chan bool, len(all))
+	b.tasks = make(chan func(), buildP)
 
 	// Initialize per-action execution state.
 	for _, a := range all {
@@ -1359,6 +1362,8 @@ func (b *builder) do(root *action) {
 					a := b.ready.pop()
 					b.exec.Unlock()
 					handle(a)
+				case task := <-b.tasks:
+					task()
 				case <-interrupted:
 					setExitStatus(1)
 					return
@@ -3348,41 +3353,48 @@ func (b *builder) cgo(a *action, cgoExe, obj string, pcCFLAGS, pcLDFLAGS, cgofil
 	}
 	outGo = append(outGo, gofiles...)
 
+	var tasks []func()
+	var results chan error
+
 	// gcc
 	cflags := stringList(cgoCPPFLAGS, cgoCFLAGS)
 	for _, cfile := range cfiles {
+		cfile := cfile
 		ofile := obj + cfile[:len(cfile)-1] + "o"
-		if err := b.gcc(p, ofile, cflags, obj+cfile); err != nil {
-			return nil, nil, err
-		}
+		tasks = append(tasks, func() {
+			results <- b.gcc(p, ofile, cflags, obj+cfile)
+		})
 		outObj = append(outObj, ofile)
 	}
 
 	for _, file := range gccfiles {
+		file := file
 		base := filepath.Base(file)
 		ofile := obj + cgoRe.ReplaceAllString(base[:len(base)-1], "_") + "o"
-		if err := b.gcc(p, ofile, cflags, file); err != nil {
-			return nil, nil, err
-		}
+		tasks = append(tasks, func() {
+			results <- b.gcc(p, ofile, cflags, file)
+		})
 		outObj = append(outObj, ofile)
 	}
 
 	cxxflags := stringList(cgoCPPFLAGS, cgoCXXFLAGS)
 	for _, file := range gxxfiles {
+		file := file
 		// Append .o to the file, just in case the pkg has file.c and file.cpp
 		ofile := obj + cgoRe.ReplaceAllString(filepath.Base(file), "_") + ".o"
-		if err := b.gxx(p, ofile, cxxflags, file); err != nil {
-			return nil, nil, err
-		}
+		tasks = append(tasks, func() {
+			results <- b.gxx(p, ofile, cxxflags, file)
+		})
 		outObj = append(outObj, ofile)
 	}
 
 	for _, file := range mfiles {
+		file := file
 		// Append .o to the file, just in case the pkg has file.c and file.m
 		ofile := obj + cgoRe.ReplaceAllString(filepath.Base(file), "_") + ".o"
-		if err := b.gcc(p, ofile, cflags, file); err != nil {
-			return nil, nil, err
-		}
+		tasks = append(tasks, func() {
+			results <- b.gcc(p, ofile, cflags, file)
+		})
 		outObj = append(outObj, ofile)
 	}
 
@@ -3396,6 +3408,33 @@ func (b *builder) cgo(a *action, cgoExe, obj string, pcCFLAGS, pcLDFLAGS, cgofil
 		outObj = append(outObj, ofile)
 	}
 
+	// Give the results channel enough capacity so that sending the
+	// result is guaranteed not to block.
+	results = make(chan error, len(tasks))
+
+	// Feed the tasks into the b.tasks channel on a separate goroutine
+	// because the b.tasks channel's limited capacity might cause
+	// sending the task to block.
+	go func() {
+		for _, task := range tasks {
+			b.tasks <- task
+		}
+	}()
+
+	// Loop until we've received results from all of our tasks or an
+	// error occurs.
+	for count := 0; count < len(tasks); {
+		select {
+		case err := <-results:
+			if err != nil {
+				return nil, nil, err
+			}
+			count++
+		case task := <-b.tasks:
+			task()
+		}
+	}
+
 	switch buildToolchain.(type) {
 	case gcToolchain:
 		importGo := obj + "_cgo_import.go"

