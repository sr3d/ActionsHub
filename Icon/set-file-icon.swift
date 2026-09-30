#!/usr/bin/env swift
// Sets a file's (or folder's) custom Finder icon.
//   swift Icon/set-file-icon.swift <icon.icns> <target-path>
import AppKit

let args = CommandLine.arguments
guard args.count == 3, let image = NSImage(contentsOfFile: args[1]) else {
    FileHandle.standardError.write(Data("usage: set-file-icon.swift <icon> <target>\n".utf8))
    exit(1)
}
exit(NSWorkspace.shared.setIcon(image, forFile: args[2], options: []) ? 0 : 1)
