#!/usr/bin/env python3
"""
本地预览 Web 导出产物。

    python3 tools/serve_web.py [端口]        # 默认 8000
    python3 tools/serve_web.py 8000 build    # 指定导出目录

为什么不能直接用 python3 -m http.server：

  1. .wasm 必须带 application/wasm 这个 MIME。
     Python 的老版本 http.server 不认 .wasm，会当成
     application/octet-stream，浏览器直接拒载。

  2. 开了 COOP/COEP 两个响应头。
     单线程构建其实不需要，但加上没坏处 ——
     以后哪天开线程（或换支持线程的模板）就不用再改托管配置。

  3. 关掉缓存。改一次导出一次，缓存会让你刷新半天还在看旧版本。

真要上线时，这个脚本只是「本地验证用」，
正式托管请看 DEPLOY.md。
"""
import functools
import os
import sys
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8000
ROOT = sys.argv[2] if len(sys.argv) > 2 else "build"


class Handler(SimpleHTTPRequestHandler):
    extensions_map = {
        **SimpleHTTPRequestHandler.extensions_map,
        ".wasm": "application/wasm",
        ".js": "text/javascript",
        ".mjs": "text/javascript",
        ".json": "application/json",
        ".pck": "application/octet-stream",
    }

    def end_headers(self):
        # 跨源隔离：启用后 SharedArrayBuffer 可用（多线程构建需要）
        self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
        # 开发期禁用缓存
        self.send_header("Cache-Control", "no-store, must-revalidate")
        self.send_header("Access-Control-Allow-Origin", "*")
        SimpleHTTPRequestHandler.end_headers(self)

    def log_message(self, fmt, *args):
        sys.stderr.write("  %s\n" % (fmt % args))


def main():
    root = os.path.abspath(ROOT)
    if not os.path.isdir(root):
        print("目录不存在: %s" % root)
        print("先跑一次 Web 导出（Godot: Project > Export > Web > Export Project）")
        return 1
    if not os.path.exists(os.path.join(root, "index.html")):
        print("警告: %s 里没有 index.html —— 确认导出路径选的是目录且文件名是 index.html"
              % root)

    handler = functools.partial(Handler, directory=root)
    srv = ThreadingHTTPServer(("0.0.0.0", PORT), handler)
    print("Serving %s" % root)
    print("  http://localhost:%d/" % PORT)
    print("  Ctrl+C 停止")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("\n已停止")
    return 0


if __name__ == "__main__":
    sys.exit(main())
