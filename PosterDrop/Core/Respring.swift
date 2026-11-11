//
//  Respring.swift
//  PosterDrop
//
//  NeoSpring：通过 WebKit GPU 进程把 SpringBoard 打崩，实现「不重启系统的 respring」。
//  原理与实现来自 @neonmodder123 / @skadz108 / @rooootdev 的 NeoSpring 项目。
//

import Foundation
import UIKit
import WebKit

enum Respring {

    static let neoSpringHTML = """
<!DOCTYPE html>
<html>
    <body>
        <!-- big credit to @neonmodder123 & @skadz108 (neospring) -->
        <iframe id="frame" srcdoc="" sandbox="allow-forms allow-modals allow-orientation-lock allow-pointer-lock allow-popups allow-presentation allow-scripts"></iframe>
        <script>
            const frame = document.getElementById('frame');
            const funfun = `
                <html>
                <body>
                    <script>
                        const container = document.createElement('div');
                        container.style.cssText = 'perspective: 1px; perspective-origin: 9999999% 9999999%;';
                        document.body.appendChild(container);

                        for (let i = 0; i < 500; i++) {
                            let d = document.createElement('div');
                            d.style.cssText = 'position: absolute; width: 100vw; height: 100vh; backdrop-filter: blur(100px); -webkit-backdrop-filter: blur(100px); transform: translate3d(100000px, 100000px, ' + i + 'px) rotateY(90deg);';
                            container.appendChild(d);
                        }

                        setInterval(() => {
                            navigator.share({ title: 'R', text: 'R'.repeat(100000) }).catch(() => {});
                            let x = new Uint8Array(1024 * 1024 * 10);
                            crypto.getRandomValues(x);
                        }, 0);
                    <\\/script>
                </body>
                </html>
            `;

            frame.srcdoc = funfun;
        </script>
    </body>
</html>
"""

    /// 挂一个全屏 WKWebView 到 key window 上，触发 GPU 进程崩溃 → SpringBoard 重启。
    static func triggerNeoSpring(completion: (() -> Void)? = nil) {
        DispatchQueue.main.async {
            guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
                  let window = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first else {
                completion?()
                return
            }

            let configuration = WKWebViewConfiguration()
            configuration.defaultWebpagePreferences.allowsContentJavaScript = true

            let webView = WKWebView(frame: window.bounds, configuration: configuration)
            webView.isOpaque = true
            webView.backgroundColor = .black
            webView.tag = 0x9D0C
            window.addSubview(webView)
            webView.loadHTMLString(neoSpringHTML, baseURL: nil)

            completion?()
        }
    }

    /// 打开系统「墙纸」设置，方便立刻挑选刚注入的壁纸
    static func openWallpaperSettings() {
        let candidates = [
            "App-prefs:root=WALLPAPER",
            "App-prefs:root=Wallpaper",
            "prefs:root=WALLPAPER",
            UIApplication.openSettingsURLString
        ]

        for candidate in candidates {
            guard let url = URL(string: candidate) else { continue }
            if UIApplication.shared.canOpenURL(url) {
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
                return
            }
        }
    }
}
