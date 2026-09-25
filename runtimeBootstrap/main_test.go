package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"debug/macho"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func machoFixture(order binary.ByteOrder, wide bool, command, platform, version uint32) []byte {
	header, magic := 28, uint32(macho.Magic32)
	if wide {
		header, magic = 32, macho.Magic64
	}
	length := 16
	if command == 0x32 {
		length = 24
	}
	b := make([]byte, header+length)
	for i, v := range []uint32{magic, uint32(macho.CpuArm64), 0, 6, 1, uint32(length), 0} {
		order.PutUint32(b[i*4:], v)
	}
	order.PutUint32(b[header:], command)
	order.PutUint32(b[header+4:], uint32(length))
	if command == 0x32 {
		order.PutUint32(b[header+8:], platform)
		order.PutUint32(b[header+12:], version)
	} else {
		order.PutUint32(b[header+8:], version)
	}
	return b
}

func fatMachOFixture(slices ...[]byte) []byte {
	b := make([]byte, 8+20*len(slices))
	binary.BigEndian.PutUint32(b, macho.MagicFat)
	binary.BigEndian.PutUint32(b[4:], uint32(len(slices)))
	for i, slice := range slices {
		copySlice := append([]byte(nil), slice...)
		binary.LittleEndian.PutUint32(copySlice[8:], uint32(i))
		for j, v := range []uint32{uint32(macho.CpuArm64), uint32(i), uint32(len(b)), uint32(len(slice)), 0} {
			binary.BigEndian.PutUint32(b[8+i*20+j*4:], v)
		}
		b = append(b, copySlice...)
	}
	return b
}

func TestMachODeploymentTargetsWithoutDeveloperTools(t *testing.T) {
	// An empty PATH ensures the fixtures need no compiler or inspection tool.
	t.Setenv("PATH", t.TempDir())
	thin := func(cmd, platform, version uint32) []byte {
		return machoFixture(binary.LittleEndian, true, cmd, platform, version)
	}
	good := thin(0x32, 1, 15<<16)
	mutate := func(input []byte, offset int, value uint32) []byte {
		b := append([]byte(nil), input...)
		binary.LittleEndian.PutUint32(b[offset:], value)
		return b
	}
	withTool := append(mutate(good, 52, 1), make([]byte, 8)...)
	withTool = mutate(mutate(withTool, 20, 32), 36, 32)
	cases := []struct {
		name  string
		data  []byte
		limit string
		ok    bool
	}{
		{"build equal", good, "15.0", true},
		{"build tools", withTool, "15", true},
		{"legacy", thin(0x24, 0, 14<<16|6<<8|1), "15", true},
		{"big endian 32", machoFixture(binary.BigEndian, false, 0x24, 0, 15<<16), "15", true},
		{"fat", fatMachOFixture(good, thin(0x24, 0, 14<<16)), "15", true},
		{"high major", thin(0x32, 1, 16<<16), "15", false},
		{"high minor", thin(0x24, 0, 15<<16|1<<8), "15.0.9", false},
		{"high patch", thin(0x32, 1, 15<<16|2), "15.0.1", false},
		{"ios", thin(0x32, 2, 14<<16), "15", false},
		{"legacy ios", thin(0x25, 0, 14<<16), "15", false},
		{"missing", thin(0x777, 0, 0), "15", false},
		{"fat high second", fatMachOFixture(good, thin(0x24, 0, 16<<16)), "15", false},
		{"fat missing second", fatMachOFixture(good, thin(0x777, 0, 0)), "15", false},
		{"fat truncated", fatMachOFixture(good)[:40], "15", false},
		{"header truncated", good[:27], "15", false},
		{"command truncated", good[:len(good)-1], "15", false},
		{"short build", mutate(thin(0x24, 0, 15<<16), 32, 0x32), "15", false},
		{"short legacy", mutate(good, 32, 0x24), "15", false},
		{"bad command size", mutate(good, 36, 7), "15", false},
		{"bad tool count", mutate(good, 52, 1), "15", false},
		{"bad command count", mutate(good, 16, 0), "15", false},
		{"too many commands", mutate(good, 16, 2), "15", false},
		{"invalid magic", []byte("bad magic"), "15", false},
		{"empty fat", fatMachOFixture(), "15", false},
		{"invalid limit", good, "", false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "fixture.dylib")
			if err := os.WriteFile(path, tc.data, 0600); err != nil {
				t.Fatal(err)
			}
			err := verifyMachOMinOS(path, tc.limit)
			if (err == nil) != tc.ok {
				t.Fatalf("accepted=%v, want %v: %v", err == nil, tc.ok, err)
			}
		})
	}
}

func fixtureHash(b []byte) string { s := sha256.Sum256(b); return hex.EncodeToString(s[:]) }
func fixtureManifest() manifest {
	b := []byte("runtime")
	h := fixtureHash(b)
	return manifest{SchemaVersion: 1, Component: "wine-runtime", Version: "fixture-r1", MinimumMacOS: "15.0", Source: sourceSpec{URL: "https://github.com/example/release.dmg", AllowedRedirectHosts: []string{"github.com"}, ByteCount: 2, SHA256: stringsRepeat("a", 64), RuntimeRoot: "App.app/Contents/Resources/runtime"}, SourceVerificationFiles: []fileSpec{{RelativePath: "bin/wine", SHA256: h, Executable: true}}, Patches: []patchSpec{{PatchRelativePath: "winemac.so", TargetRelativePath: "lib/winemac.so", SHA256: h, MachOMinOSAtMost: "15.0"}, {PatchRelativePath: "gmp", TargetRelativePath: "lib/gmp", SHA256: h, MachOMinOSAtMost: "15.0"}, {PatchRelativePath: "pcre", TargetRelativePath: "lib/pcre", SHA256: h, MachOMinOSAtMost: "15.0"}, {PatchRelativePath: "zstd", TargetRelativePath: "lib/zstd", SHA256: h, MachOMinOSAtMost: "15.0"}}, FinalVerificationFiles: []fileSpec{{RelativePath: "bin/wine", SHA256: h, Executable: true}}}
}
func stringsRepeat(s string, n int) string {
	var b bytes.Buffer
	for i := 0; i < n; i++ {
		b.WriteString(s)
	}
	return b.String()
}
func TestShippedManifestParsesBeforeFirstRuntimeDownload(t *testing.T) {
	// The first install has no cached runtime to bypass parsing. Keep the
	// bootstrap decoder in step with the exact manifest copied into the App.
	path, err := filepath.Abs("runtime-manifest.json")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := readManifest(path); err != nil {
		t.Fatal(err)
	}
}
func TestManifestRejectsBadURLHashAndPaths(t *testing.T) {
	m := fixtureManifest()
	if err := validateManifest(m); err != nil {
		t.Fatal(err)
	}
	m.Source.URL = "http://github.com/x"
	if validateManifest(m) == nil {
		t.Fatal("accepted insecure URL")
	}
	m = fixtureManifest()
	m.Source.SHA256 = "bad"
	if validateManifest(m) == nil {
		t.Fatal("accepted bad source hash")
	}
	m = fixtureManifest()
	m.Patches[0].TargetRelativePath = "../escape"
	if validateManifest(m) == nil {
		t.Fatal("accepted escaping patch")
	}
	m = fixtureManifest()
	m.Source.AllowedRedirectHosts = []string{"evil.example"}
	if validateManifest(m) == nil {
		t.Fatal("accepted source host outside allowlist")
	}
}
func TestVerifyTreeRejectsSymlinkAndHashMismatch(t *testing.T) {
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "bin"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "bin/wine"), []byte("runtime"), 0700); err != nil {
		t.Fatal(err)
	}
	m := fixtureManifest()
	if err := verifyTree(root, m.FinalVerificationFiles, false); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(filepath.Join(root, "bin/wine")); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("elsewhere", filepath.Join(root, "bin/wine")); err != nil {
		t.Fatal(err)
	}
	if err := verifyTree(root, m.FinalVerificationFiles, false); err == nil {
		t.Fatal("accepted symlink")
	}
}
func TestExistingCurrentRefusesOverwrite(t *testing.T) {
	root := t.TempDir()
	if err := os.Symlink("old", filepath.Join(root, "current")); err != nil {
		t.Fatal(err)
	}
	m := fixtureManifest()
	if err := install(nil, m, root, t.TempDir(), os.Stderr); err == nil {
		t.Fatal("accepted overwriting current")
	}
}

func writeFinalFixture(t *testing.T, root string, m manifest) string {
	t.Helper()
	final := filepath.Join(root, m.Version)
	if err := os.MkdirAll(filepath.Join(final, "bin"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(final, "bin", "wine"), []byte("runtime"), 0700); err != nil {
		t.Fatal(err)
	}
	return final
}

func TestRecoverPublishedRuntimeRestoresCurrentAfterCrashWindow(t *testing.T) {
	root := t.TempDir()
	m := fixtureManifest()
	writeFinalFixture(t, root, m) // Simulates crash immediately after os.Rename(runtimeStage, final).
	recovered, err := recoverPublishedRuntime(m, root, false)
	if err != nil || !recovered {
		t.Fatalf("did not recover published runtime: recovered=%v err=%v", recovered, err)
	}
	target, err := os.Readlink(filepath.Join(root, "current"))
	if err != nil || target != m.Version {
		t.Fatalf("unexpected restored current link: target=%q err=%v", target, err)
	}
}

func TestRecoverPublishedRuntimeIsIdempotent(t *testing.T) {
	root := t.TempDir()
	m := fixtureManifest()
	writeFinalFixture(t, root, m)
	if err := os.Symlink(m.Version, filepath.Join(root, "current")); err != nil {
		t.Fatal(err)
	}
	recovered, err := recoverPublishedRuntime(m, root, false)
	if err != nil || !recovered {
		t.Fatalf("did not accept already-complete runtime: recovered=%v err=%v", recovered, err)
	}
}

func TestRecoverPublishedRuntimeFailsClosedOnConflictingCurrent(t *testing.T) {
	root := t.TempDir()
	m := fixtureManifest()
	writeFinalFixture(t, root, m)
	if err := os.Symlink("another-version", filepath.Join(root, "current")); err != nil {
		t.Fatal(err)
	}
	if _, err := recoverPublishedRuntime(m, root, false); err == nil {
		t.Fatal("accepted conflicting current link")
	}
}

func TestRecoverPublishedRuntimeRejectsInvalidFinalBeforeLinking(t *testing.T) {
	root := t.TempDir()
	m := fixtureManifest()
	final := filepath.Join(root, m.Version)
	if err := os.MkdirAll(final, 0700); err != nil {
		t.Fatal(err)
	}
	if _, err := recoverPublishedRuntime(m, root, false); err == nil {
		t.Fatal("accepted unverified final runtime")
	}
	if _, err := os.Lstat(filepath.Join(root, "current")); !os.IsNotExist(err) {
		t.Fatalf("created current despite invalid final: %v", err)
	}
}

func TestDownloadProgressIsBoundedAndMachineReadable(t *testing.T) {
	payload := bytes.Repeat([]byte("x"), 100)
	var destination, progress bytes.Buffer
	if err := writeVerifiedWithProgress(&destination, bytes.NewReader(payload), int64(len(payload)), fixtureHash(payload), &progress); err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimSpace(progress.String()), "\n")
	if len(lines) != 1 { // A single large source read still produces one meaningful update.
		t.Fatalf("unexpected progress line count %d: %q", len(lines), progress.String())
	}
	if !strings.Contains(lines[0], "stage=download bytes=100 total=100 percent=100") {
		t.Fatalf("progress was not machine-readable: %q", progress.String())
	}
}

func TestPartialDownloadFixtureIsRejected(t *testing.T) {
	payload := []byte("full runtime fixture")
	if err := writeVerified(io.Discard, bytes.NewReader(payload[:len(payload)-1]), int64(len(payload)), fixtureHash(payload)); err == nil {
		t.Fatal("accepted partial runtime download")
	}
}

func TestDownloadCancellationStopsHTTPStream(t *testing.T) {
	started := make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Length", "4194304")
		w.WriteHeader(http.StatusOK)
		if _, err := w.Write(bytes.Repeat([]byte("x"), 1024)); err != nil {
			return
		}
		if f, ok := w.(http.Flusher); ok {
			f.Flush()
		}
		close(started)
		<-r.Context().Done()
	}))
	defer server.Close()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	url := server.URL
	m := fixtureManifest()
	m.Source.URL = url
	m.Source.AllowedRedirectHosts = []string{strings.TrimPrefix(url, "http://")}
	m.Source.ByteCount = 4 * 1024 * 1024
	target := filepath.Join(t.TempDir(), "runtime.dmg")
	result := make(chan error, 1)
	go func() { result <- download(ctx, m, target, io.Discard) }()
	select {
	case <-started:
		cancel()
	case <-time.After(3 * time.Second):
		t.Fatal("test server did not begin streaming")
	}
	select {
	case err := <-result:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("expected cancellation, got %v", err)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("download did not return after context cancellation")
	}
}

func TestEmojiCandidatePEPatch(t *testing.T) {
	path := filepath.Join("..", "wineEmojiPatch", "releasePayloads", "gdi32.dll")
	if err := verifyPEMachine(path, "amd64"); err != nil {
		t.Fatalf("audited emoji GDI payload is not an x86_64 PE DLL: %v", err)
	}
	wrong := filepath.Join(t.TempDir(), "gdi32.dll")
	if err := os.WriteFile(wrong, []byte("not a PE DLL"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := verifyPEMachine(wrong, "amd64"); err == nil {
		t.Fatal("accepted non-PE patch payload")
	}
}

// ── 离线载荷（--payload-dmg）────────────────────────────────────────────────────
// 契约：给了本地镜像就完全替代网络，逐字节校验；不一致 fail closed，绝不回退联网。

func realTempDir(t *testing.T) string {
	t.Helper()
	path, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	return path
}

// buildRuntimeDMG wraps a runtime tree in the same kind of compressed image the
// upstream publisher ships, so the offline path exercises the real mount flow.
func buildRuntimeDMG(t *testing.T, sourceRoot string) string {
	t.Helper()
	if info, err := os.Stat("/usr/bin/hdiutil"); err != nil || info.Mode()&0111 == 0 {
		t.Skip("hdiutil is required for the offline image fixture")
	}
	dmg := filepath.Join(t.TempDir(), "BaseRuntime.dmg")
	output, err := exec.Command("/usr/bin/hdiutil", "create", "-quiet", "-format", "UDZO",
		"-volname", "IdentityVRuntimeFixture", "-srcfolder", sourceRoot, dmg).CombinedOutput()
	if err != nil {
		t.Fatalf("cannot build DMG fixture: %v: %s", err, output)
	}
	return dmg
}

// offlineRuntimeFixture returns a manifest, patch root and image whose bytes all
// agree, mirroring the packaged offline layout (BaseRuntime.dmg + RuntimePatches).
func offlineRuntimeFixture(t *testing.T) (manifest, string, string) {
	t.Helper()
	patches := machoFixture(binary.LittleEndian, true, 0x32, 1, 15<<16)
	patchHash := fixtureHash(patches)
	patchRoot := t.TempDir()
	if err := os.MkdirAll(filepath.Join(patchRoot, "patches"), 0700); err != nil {
		t.Fatal(err)
	}
	names := []string{"winemac.so", "gmp", "pcre", "zstd"}
	specs := make([]patchSpec, 0, len(names))
	for _, name := range names {
		relative := filepath.Join("patches", name)
		if err := os.WriteFile(filepath.Join(patchRoot, relative), patches, 0600); err != nil {
			t.Fatal(err)
		}
		specs = append(specs, patchSpec{PatchRelativePath: relative, TargetRelativePath: "lib/" + name, SHA256: patchHash, MachOMinOSAtMost: "15.0"})
	}
	runtimeRoot := "App.app/Contents/Resources/runtime"
	sourceRoot := t.TempDir()
	source := filepath.Join(sourceRoot, runtimeRoot)
	if err := os.MkdirAll(filepath.Join(source, "bin"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(source, "lib"), 0700); err != nil {
		t.Fatal(err)
	}
	wine := []byte("runtime")
	if err := os.WriteFile(filepath.Join(source, "bin", "wine"), wine, 0700); err != nil {
		t.Fatal(err)
	}
	unsigned := []byte("unsigned-lib")
	if err := os.WriteFile(filepath.Join(source, "lib", "winemac.so"), unsigned, 0700); err != nil {
		t.Fatal(err)
	}
	for _, name := range names[1:] {
		if err := os.WriteFile(filepath.Join(source, "lib", name), unsigned, 0700); err != nil {
			t.Fatal(err)
		}
	}
	dmg := buildRuntimeDMG(t, sourceRoot)
	info, err := os.Stat(dmg)
	if err != nil {
		t.Fatal(err)
	}
	dmgHash, err := hashFile(dmg)
	if err != nil {
		t.Fatal(err)
	}
	final := []fileSpec{{RelativePath: "bin/wine", SHA256: fixtureHash(wine), Executable: true}}
	for _, name := range names {
		final = append(final, fileSpec{RelativePath: "lib/" + name, SHA256: patchHash, MachOMinOSAtMost: "15.0"})
	}
	m := manifest{
		SchemaVersion: 1, Component: "wine-runtime", Version: "fixture-r1", MinimumMacOS: "15.0",
		Source: sourceSpec{
			URL: "https://127.0.0.1:1/BaseRuntime.dmg", AllowedRedirectHosts: []string{"127.0.0.1:1"},
			ByteCount: info.Size(), SHA256: dmgHash, RuntimeRoot: runtimeRoot,
		},
		SourceVerificationFiles: []fileSpec{{RelativePath: "bin/wine", SHA256: fixtureHash(wine), Executable: true}, {RelativePath: "lib/winemac.so", SHA256: fixtureHash(unsigned)}},
		Patches:                 specs,
		FinalVerificationFiles:  final,
	}
	return m, patchRoot, dmg
}

func TestOfflinePayloadImageInstallsWithoutNetwork(t *testing.T) {
	m, patchRoot, dmg := offlineRuntimeFixture(t)
	destination := realTempDir(t)
	var progress bytes.Buffer
	if err := installWithPayload(context.Background(), m, destination, patchRoot, dmg, &progress); err != nil {
		t.Fatalf("offline install failed: %v", err)
	}
	final := filepath.Join(destination, m.Version)
	if err := verifyTree(final, m.FinalVerificationFiles, true); err != nil {
		t.Fatalf("published runtime does not verify: %v", err)
	}
	target, err := os.Readlink(filepath.Join(destination, "current"))
	if err != nil || target != m.Version {
		t.Fatalf("unexpected current link: target=%q err=%v", target, err)
	}
	patched, err := os.ReadFile(filepath.Join(final, "lib", "winemac.so"))
	if err != nil || fixtureHash(patched) != m.Patches[0].SHA256 {
		t.Fatalf("patch payload was not applied: err=%v", err)
	}
	text := progress.String()
	for _, want := range []string{"using offline runtime payload", "runtime-bootstrap stage=download bytes=0 total=", "percent=100", "runtime bootstrap completed"} {
		if !strings.Contains(text, want) {
			t.Fatalf("progress stream missing %q: %q", want, text)
		}
	}
	if strings.Contains(text, "downloading runtime from original publisher") {
		t.Fatalf("offline install still announced a download: %q", text)
	}
}

func TestOfflinePayloadVerificationFailsClosed(t *testing.T) {
	payload := []byte("offline runtime image bytes")
	m := fixtureManifest()
	m.Source.ByteCount = int64(len(payload))
	m.Source.SHA256 = fixtureHash(payload)
	good := filepath.Join(t.TempDir(), "BaseRuntime.dmg")
	if err := os.WriteFile(good, payload, 0600); err != nil {
		t.Fatal(err)
	}
	var progress bytes.Buffer
	if err := verifyLocalSource(context.Background(), m, good, &progress); err != nil {
		t.Fatalf("valid offline payload rejected: %v", err)
	}
	for _, want := range []string{"runtime-bootstrap stage=download bytes=0 total=", "percent=0", "percent=100"} {
		if !strings.Contains(progress.String(), want) {
			t.Fatalf("progress stream missing %q: %q", want, progress.String())
		}
	}
	mutated := append([]byte(nil), payload...)
	mutated[0] ^= 1
	cases := []struct {
		name string
		path string
	}{
		{"size mismatch", writeFixtureFile(t, "short.dmg", payload[:len(payload)-1])},
		{"hash mismatch", writeFixtureFile(t, "mutated.dmg", mutated)},
		{"missing file", filepath.Join(t.TempDir(), "missing.dmg")},
	}
	link := filepath.Join(t.TempDir(), "link.dmg")
	if err := os.Symlink(good, link); err != nil {
		t.Fatal(err)
	}
	cases = append(cases, struct {
		name string
		path string
	}{"symlink", link})
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if err := verifyLocalSource(context.Background(), m, tc.path, io.Discard); err == nil {
				t.Fatal("invalid offline payload was accepted")
			}
		})
	}
}

func writeFixtureFile(t *testing.T, name string, data []byte) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), name)
	if err := os.WriteFile(path, data, 0600); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestOfflineInstallRejectsTamperedPayloadWithoutNetworkFallback(t *testing.T) {
	m := fixtureManifest()
	m.Source.ByteCount = 8
	m.Source.SHA256 = fixtureHash([]byte("expected"))
	payload := writeFixtureFile(t, "BaseRuntime.dmg", []byte("tampered"))
	destination := realTempDir(t)
	var out bytes.Buffer
	if err := installWithPayload(context.Background(), m, destination, t.TempDir(), payload, &out); err == nil {
		t.Fatal("accepted a tampered offline payload")
	}
	if strings.Contains(out.String(), "downloading runtime from original publisher") {
		t.Fatalf("offline failure fell back to the network: %q", out.String())
	}
	if _, err := os.Lstat(filepath.Join(destination, "current")); !os.IsNotExist(err) {
		t.Fatalf("published current after a failed offline payload: %v", err)
	}
	if _, err := os.Lstat(filepath.Join(destination, m.Version)); !os.IsNotExist(err) {
		t.Fatalf("published a version after a failed offline payload: %v", err)
	}
	if _, err := os.Lstat(filepath.Join(destination, "current")); !os.IsNotExist(err) {
		t.Fatal("current must not exist after a rejected payload")
	}
}

func TestInstallWithoutOfflinePayloadStillDownloads(t *testing.T) {
	m := fixtureManifest()
	m.Source.URL = "https://127.0.0.1:1/BaseRuntime.dmg"
	m.Source.AllowedRedirectHosts = []string{"127.0.0.1:1"}
	m.Source.ByteCount = 4
	m.Source.SHA256 = stringsRepeat("a", 64)
	destination := realTempDir(t)
	var out bytes.Buffer
	if err := installWithPayload(context.Background(), m, destination, t.TempDir(), "", &out); err == nil {
		t.Fatal("expected the unreachable source to fail the online path")
	}
	if !strings.Contains(out.String(), "downloading runtime from original publisher") {
		t.Fatalf("empty payload did not use the original download path: %q", out.String())
	}
	if strings.Contains(out.String(), "offline runtime payload") {
		t.Fatalf("empty payload was treated as an offline image: %q", out.String())
	}
}
