//
//  SharedWebProcessPool.swift
//  QuickLookCodeShared
//
//  Provides a single shared WKProcessPool so all WKWebView instances in the extension
//  reuse the same web content process. This avoids the ~100–200 ms cold-start cost of
//  spinning up a fresh web content process each time macOS re-instantiates the preview VC.
//

import WebKit

public enum SharedWebProcessPool {
    public static let shared = WKProcessPool()
}
