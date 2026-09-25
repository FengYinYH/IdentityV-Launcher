package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

type roundTripFunc func(*http.Request) (*http.Response, error)

func (function roundTripFunc) RoundTrip(request *http.Request) (*http.Response, error) {
	return function(request)
}

func fixtureManifest(payloads map[string][]byte) ComponentManifest {
	files := make([]ComponentFile, 0, 3)
	for _, name := range []string{"downloadIPC.exe", "OrbitSDK.dll", "aria2c.exe"} {
		hash := sha256.Sum256(payloads[name])
		files = append(files, ComponentFile{Filename: name, ByteCount: int64(len(payloads[name])), SHA256: hex.EncodeToString(hash[:])})
	}
	commit := strings.Repeat("a", 40)
	return ComponentManifest{
		SchemaVersion: 1,
		Component:     "netease-download-core",
		Acquisition: Acquisition{
			Mode:          "download-on-first-use",
			Repository:    "https://github.com/KKeygen/idv-login",
			Commit:        commit,
			SourceBaseURL: "https://raw.githubusercontent.com/KKeygen/idv-login/" + commit + "/binaries/",
		},
		RedistributionStatus: "not-bundled-download-on-first-use",
		Files:                files,
	}
}

func fixturePayloads() map[string][]byte {
	return map[string][]byte{
		"downloadIPC.exe": append([]byte("MZ"), bytes.Repeat([]byte{1}, 31)...),
		"OrbitSDK.dll":    append([]byte("MZ"), bytes.Repeat([]byte{2}, 19)...),
		"aria2c.exe":      append([]byte("MZ"), bytes.Repeat([]byte{3}, 23)...),
	}
}

func realTempDir(t *testing.T) string {
	t.Helper()
	directory, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	return directory
}

func clientFor(payloads map[string][]byte, truncate string) *http.Client {
	return &http.Client{Transport: roundTripFunc(func(request *http.Request) (*http.Response, error) {
		name := filepath.Base(request.URL.Path)
		payload := payloads[name]
		if name == truncate && len(payload) > 2 {
			payload = payload[:len(payload)-1]
		}
		return &http.Response{StatusCode: http.StatusOK, ContentLength: int64(len(payload)), Body: io.NopCloser(bytes.NewReader(payload)), Header: make(http.Header)}, nil
	})}
}

func TestInstallVerifyAndReuse(t *testing.T) {
	payloads := fixturePayloads()
	manifest := fixtureManifest(payloads)
	root := filepath.Join(realTempDir(t), "components", "netease-download-core")
	var events bytes.Buffer
	if err := install(context.Background(), manifest, root, clientFor(payloads, ""), &events); err != nil {
		t.Fatal(err)
	}
	version := filepath.Join(root, manifest.Acquisition.Commit)
	if err := verifyInstalled(version, manifest); err != nil {
		t.Fatal(err)
	}
	current, err := filepath.EvalSymlinks(filepath.Join(root, "current"))
	if err != nil || current != version {
		t.Fatal(current, err)
	}
	if !strings.Contains(events.String(), `"event":"completed"`) {
		t.Fatal(events.String())
	}
	if err = install(context.Background(), manifest, root, clientFor(nil, ""), io.Discard); err != nil {
		t.Fatal("verified install should be reused without network", err)
	}
}

func TestTruncatedDownloadLeavesNoVersionOrCurrent(t *testing.T) {
	payloads := fixturePayloads()
	manifest := fixtureManifest(payloads)
	root := filepath.Join(realTempDir(t), "components", "netease-download-core")
	if err := install(context.Background(), manifest, root, clientFor(payloads, "OrbitSDK.dll"), io.Discard); err == nil {
		t.Fatal("truncated download accepted")
	}
	if _, err := filepath.EvalSymlinks(filepath.Join(root, "current")); err == nil {
		t.Fatal("failed acquisition published current")
	}
	if _, err := filepath.EvalSymlinks(filepath.Join(root, manifest.Acquisition.Commit)); err == nil {
		t.Fatal("failed acquisition published version")
	}
}

func TestCorruptExistingVersionIsQuarantinedAndRecovered(t *testing.T) {
	payloads := fixturePayloads()
	manifest := fixtureManifest(payloads)
	root := filepath.Join(realTempDir(t), "components", "netease-download-core")
	if err := install(context.Background(), manifest, root, clientFor(payloads, ""), io.Discard); err != nil {
		t.Fatal(err)
	}
	version := filepath.Join(root, manifest.Acquisition.Commit)
	corrupt := bytes.Repeat([]byte{9}, len(payloads["OrbitSDK.dll"]))
	copy(corrupt[:2], []byte("MZ"))
	if err := os.WriteFile(filepath.Join(version, "OrbitSDK.dll"), corrupt, 0600); err != nil {
		t.Fatal(err)
	}
	var events bytes.Buffer
	if err := install(context.Background(), manifest, root, clientFor(payloads, ""), &events); err != nil {
		t.Fatal(err)
	}
	if err := verifyInstalled(version, manifest); err != nil {
		t.Fatal(err)
	}
	quarantined, err := filepath.Glob(filepath.Join(root, ".quarantine-"+manifest.Acquisition.Commit+"-*"))
	if err != nil || len(quarantined) != 1 {
		t.Fatal("corrupt version was not recoverably quarantined", quarantined, err)
	}
	if !strings.Contains(events.String(), `"event":"quarantined"`) {
		t.Fatal(events.String())
	}
}

func TestCurrentDirectoryIsQuarantined(t *testing.T) {
	payloads := fixturePayloads()
	manifest := fixtureManifest(payloads)
	root := filepath.Join(realTempDir(t), "components", "netease-download-core")
	if err := ensureRealDirectory(filepath.Join(root, "current")); err != nil {
		t.Fatal(err)
	}
	if err := install(context.Background(), manifest, root, clientFor(payloads, ""), io.Discard); err != nil {
		t.Fatal(err)
	}
	current, err := filepath.EvalSymlinks(filepath.Join(root, "current"))
	if err != nil || current != filepath.Join(root, manifest.Acquisition.Commit) {
		t.Fatal(current, err)
	}
	quarantined, err := filepath.Glob(filepath.Join(root, ".quarantine-current-*"))
	if err != nil || len(quarantined) != 1 {
		t.Fatal("invalid current directory was not quarantined", quarantined, err)
	}
}

func TestManifestAndDestinationSafety(t *testing.T) {
	payloads := fixturePayloads()
	manifest := fixtureManifest(payloads)
	manifest.Acquisition.SourceBaseURL = "https://example.com/binaries/"
	if validateManifest(manifest) == nil {
		t.Fatal("untrusted source accepted")
	}
	base := realTempDir(t)
	outside := realTempDir(t)
	link := filepath.Join(base, "linked")
	if err := os.Symlink(outside, link); err != nil {
		t.Fatal(err)
	}
	if err := ensureRealDirectory(filepath.Join(link, "component")); err == nil {
		t.Fatal("symlink destination accepted")
	}
}

// ── 离线载荷（--payload-dir）────────────────────────────────────────────────────
// 契约：给了包内目录就从本地读取全部文件并逐一校验；缺失或校验失败 fail closed，
// 绝不回退联网；未给该参数时完全走原有网络路径。

func TestOfflinePayloadDirectoryInstallsWithoutNetwork(t *testing.T) {
	payloads := fixturePayloads()
	manifest := fixtureManifest(payloads)
	root := filepath.Join(realTempDir(t), "components", "netease-download-core")
	payloadDirectory := t.TempDir()
	for name, content := range payloads {
		if err := os.WriteFile(filepath.Join(payloadDirectory, name), content, 0600); err != nil {
			t.Fatal(err)
		}
	}
	client := &http.Client{Transport: roundTripFunc(func(*http.Request) (*http.Response, error) {
		t.Fatal("offline payload reached the network")
		return nil, nil
	})}
	var events bytes.Buffer
	if err := installWithPayload(context.Background(), manifest, root, payloadDirectory, client, &events); err != nil {
		t.Fatalf("offline install failed: %v", err)
	}
	version := filepath.Join(root, manifest.Acquisition.Commit)
	if err := verifyInstalled(version, manifest); err != nil {
		t.Fatal(err)
	}
	current, err := filepath.EvalSymlinks(filepath.Join(root, "current"))
	if err != nil || current != version {
		t.Fatalf("unexpected current: %q err=%v", current, err)
	}
	for _, want := range []string{`"event":"downloading"`, `"event":"verified"`, `"event":"completed"`} {
		if !strings.Contains(events.String(), want) {
			t.Fatalf("missing %s in %s", want, events.String())
		}
	}
	// A verified version must be reused even when the payload directory is gone.
	if err = installWithPayload(context.Background(), manifest, root, filepath.Join(t.TempDir(), "absent"), client, io.Discard); err != nil {
		t.Fatalf("verified offline install was not reused: %v", err)
	}
}

func TestOfflinePayloadFailsClosed(t *testing.T) {
	failingClient := func(t *testing.T) *http.Client {
		return &http.Client{Transport: roundTripFunc(func(*http.Request) (*http.Response, error) {
			t.Fatal("failed offline payload fell back to the network")
			return nil, nil
		})}
	}
	// clone copies the fixture so "what the manifest pins" and "what the payload
	// directory ships" can diverge deliberately.
	clone := func(input map[string][]byte) map[string][]byte {
		output := make(map[string][]byte, len(input))
		for name, content := range input {
			output[name] = append([]byte(nil), content...)
		}
		return output
	}
	original := fixturePayloads()
	notPE := clone(original)
	notPE["aria2c.exe"] = append([]byte("ZZ"), bytes.Repeat([]byte{3}, 23)...)
	cases := []struct {
		name    string
		pinned  map[string][]byte
		shipped map[string][]byte
		prepare func(t *testing.T, directory string)
	}{
		{name: "missing file", pinned: clone(original), shipped: clone(original), prepare: func(t *testing.T, directory string) {
			if err := os.Remove(filepath.Join(directory, "aria2c.exe")); err != nil {
				t.Fatal(err)
			}
		}},
		{name: "truncated", pinned: clone(original), shipped: func() map[string][]byte {
			shipped := clone(original)
			shipped["OrbitSDK.dll"] = shipped["OrbitSDK.dll"][:len(shipped["OrbitSDK.dll"])-1]
			return shipped
		}()},
		{name: "hash mismatch", pinned: clone(original), shipped: func() map[string][]byte {
			shipped := clone(original)
			shipped["downloadIPC.exe"][3] ^= 1
			return shipped
		}()},
		// The manifest pins a file with the right size and digest that is still
		// not a PE image, so only the MZ check can reject it.
		{name: "missing PE magic", pinned: clone(notPE), shipped: clone(notPE)},
		{name: "symlinked file", pinned: clone(original), shipped: clone(original), prepare: func(t *testing.T, directory string) {
			link := filepath.Join(directory, "OrbitSDK.dll")
			if err := os.Remove(link); err != nil {
				t.Fatal(err)
			}
			if err := os.Symlink(filepath.Join(directory, "downloadIPC.exe"), link); err != nil {
				t.Fatal(err)
			}
		}},
	}
	for _, testCase := range cases {
		t.Run(testCase.name, func(t *testing.T) {
			manifest := fixtureManifest(testCase.pinned)
			root := filepath.Join(realTempDir(t), "components", "netease-download-core")
			directory := t.TempDir()
			for name, content := range testCase.shipped {
				if err := os.WriteFile(filepath.Join(directory, name), content, 0600); err != nil {
					t.Fatal(err)
				}
			}
			if testCase.prepare != nil {
				testCase.prepare(t, directory)
			}
			if err := installWithPayload(context.Background(), manifest, root, directory, failingClient(t), io.Discard); err == nil {
				t.Fatal("invalid offline payload was accepted")
			}
			if _, err := filepath.EvalSymlinks(filepath.Join(root, "current")); err == nil {
				t.Fatal("failed offline acquisition published current")
			}
			if _, err := filepath.EvalSymlinks(filepath.Join(root, manifest.Acquisition.Commit)); err == nil {
				t.Fatal("failed offline acquisition published a version")
			}
		})
	}
}

func TestOfflinePayloadDirectoryMustBeADirectory(t *testing.T) {
	payloads := fixturePayloads()
	manifest := fixtureManifest(payloads)
	root := filepath.Join(realTempDir(t), "components", "netease-download-core")
	notADirectory := filepath.Join(t.TempDir(), "payload")
	if err := os.WriteFile(notADirectory, []byte("not a directory"), 0600); err != nil {
		t.Fatal(err)
	}
	client := &http.Client{Transport: roundTripFunc(func(*http.Request) (*http.Response, error) {
		t.Fatal("invalid payload directory fell back to the network")
		return nil, nil
	})}
	if err := installWithPayload(context.Background(), manifest, root, notADirectory, client, io.Discard); err == nil {
		t.Fatal("a regular file as --payload-dir was accepted")
	}
}

func TestInstallWithoutPayloadDirectoryUsesNetwork(t *testing.T) {
	payloads := fixturePayloads()
	manifest := fixtureManifest(payloads)
	root := filepath.Join(realTempDir(t), "components", "netease-download-core")
	requests := 0
	client := &http.Client{Transport: roundTripFunc(func(request *http.Request) (*http.Response, error) {
		requests++
		payload := payloads[filepath.Base(request.URL.Path)]
		return &http.Response{StatusCode: http.StatusOK, ContentLength: int64(len(payload)), Body: io.NopCloser(bytes.NewReader(payload)), Header: make(http.Header)}, nil
	})}
	if err := install(context.Background(), manifest, root, client, io.Discard); err != nil {
		t.Fatal(err)
	}
	if requests != len(manifest.Files) {
		t.Fatalf("online path made %d requests, want %d", requests, len(manifest.Files))
	}
}
