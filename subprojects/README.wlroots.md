# Bundled wlroots

somewm bundles the stock upstream wlroots 0.20.2 release. No patch is applied.
`subprojects/wlroots.wrap` records the tarball URL, filename and SHA256 hash.

To prove a fresh unpack and build:

```sh
rm -rf subprojects/wlroots-0.20.2 build-test && make build-test
```
