//
//  XcodeFiles.swift
//  DevCleaner
//
//  Created by Konrad Kołakowski on 10.03.2018.
//  Copyright © 2018 One Minute Games. All rights reserved.
//
//  DevCleaner is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation; either version 3 of the License, or
//  (at your option) any later version.
//
//  DevCleaner is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with DevCleaner.  If not, see <http://www.gnu.org/licenses/>.

import Foundation
import Cocoa

// MARK: Xcode scan delegate
public protocol XcodeFilesScanDelegate: class {
    func scanWillBegin(xcodeFiles: XcodeFiles)
    func scanDidFinish(xcodeFiles: XcodeFiles)
}

// MARK: - Xcode delete delegate
public protocol XcodeFilesDeleteDelegate: class {
    func deleteWillBegin(xcodeFiles: XcodeFiles)
    func deleteInProgress(xcodeFiles: XcodeFiles, location: String, label: String, url: URL?, current: Int, total: Int)
    func deleteItemFailed(xcodeFiles: XcodeFiles, error: Error, location: String, label: String, url: URL?)
    func deleteDidFinish(xcodeFiles: XcodeFiles)
}

// MARK: - Xcode files
final public class XcodeFiles {
    // MARK: Types
    public enum Location: Int {
        case deviceSupport, archives, derivedData
        
        public static var all: [Location] {
            return [.deviceSupport, .archives, .derivedData]
        }
    }
    
    // MARK: Properties
    private var userDeveloperFolderUrl: URL
    private var customDerivedDataFolderUrl: URL?
    private var customArchivesFolderUrl: URL?
    
    public weak var scanDelegate: XcodeFilesScanDelegate?
    public weak var deleteDelegate: XcodeFilesDeleteDelegate?
    
    public private(set) var locations: [Location : XcodeFileEntry]
    
    public var totalSize: Int64 {
        return locations.values.reduce(0) { (result, entry) -> Int64 in
            return result + (entry.size.numberOfBytes ?? 0)
        }
    }
    
    public var selectedSize: Int64 {
        return locations.values.reduce(0) { (result, entry) -> Int64 in
            return result + entry.selectedSize
        }
    }
    
    // MARK: Initialization
    public init?(developerFolder: URL, customDerivedDataFolder: URL?, customArchivesFolder: URL?) {
        self.userDeveloperFolderUrl = developerFolder
        self.customDerivedDataFolderUrl = customDerivedDataFolder
        self.customArchivesFolderUrl = customArchivesFolder
        
        let _ = self.userDeveloperFolderUrl.startAccessingSecurityScopedResource()
        let _ = self.customDerivedDataFolderUrl?.startAccessingSecurityScopedResource()
        let _ = self.customArchivesFolderUrl?.startAccessingSecurityScopedResource()
        
        guard XcodeFiles.checkForXcodeDataFolders(location: developerFolder) else {
            log.error("XcodeFiles: Cannot create because Xcode cache folders doesn't seem to exist or we don't have proper access to them!")
            return nil
        }
        
        self.locations = [
            .deviceSupport: XcodeFileEntry(label: "Device Support", selected: true),
            .archives: XcodeFileEntry(label: "Archives", selected: false),
            .derivedData: XcodeFileEntry(label: "Derived Data", selected: false)
        ]
    }
    
    deinit {
        self.userDeveloperFolderUrl.stopAccessingSecurityScopedResource()
        self.customDerivedDataFolderUrl?.stopAccessingSecurityScopedResource()
        self.customArchivesFolderUrl?.stopAccessingSecurityScopedResource()
    }
    
    // MARK: Helpers
    private static func checkForXcodeDataFolders(location: URL) -> Bool {
        // check if folder exists
        let folderExists = FileManager.default.fileExists(atPath: location.path)
        
        // more checks, like folders structure
        var structureProper = true
        
        let foldersToCheck = ["Xcode", "CoreSimulator"]
        for folder in foldersToCheck {
            let folderPath = location.appendingPathComponent(folder)
            
            if !FileManager.default.fileExists(atPath: folderPath.path) {
                structureProper = false
                break
            }
        }
        
        return folderExists && structureProper
    }
    
    // runs shell command synchronously and returns an output
    @discardableResult
    private static func runShellCommand(_ command: String) -> String {
        let pipe = Pipe()
        let process = Process()
        
        process.launchPath = "/bin/sh"
        process.arguments = ["-c", command]
        process.standardOutput = pipe
        process.standardError = pipe
        
        let file = pipe.fileHandleForReading
        
        process.launch()
        
        guard let result = String(data: file.readDataToEndOfFile(), encoding: .utf8) else {
            log.error("XcodeFiles: Error while reading output from shell command: \(command)")
            return ""
        }
        
        return result
    }
    
    public func debugRepresentation() -> String {
        var result = String()
        
        for entry in self.locations.values {
            result += entry.debugRepresentation()
            result += "\n"
        }
        
        return result
    }
    
    // MARK: Creating entries
    private func deviceSupportEntry(from string: String, osLabel: String) -> DeviceSupportFileEntry? {
        let splitted = string.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
        
        // we have device too
        if splitted.count == 3 {
            let device = String(splitted[0])
            let version = Version(describing: String(splitted[1]))
            let build = String(splitted[2])
            
            if let version = version {
                return DeviceSupportFileEntry(device: device,
                                              osType: DeviceSupportFileEntry.OSType(label: osLabel),
                                              version: version,
                                              build: build,
                                              selected: true)
            } else {
                log.warning("XcodeFiles: No version for device support: \(string), skipping")
            }
        }
        
        // no device so only version and build
        if splitted.count == 2 {
            let version = Version(describing: String(splitted[0]))
            let build = String(splitted[1])
            
            if let version = version {
                return DeviceSupportFileEntry(device: nil,
                                              osType: DeviceSupportFileEntry.OSType(label: osLabel),
                                              version: version,
                                              build: build,
                                              selected: true)
            } else {
                log.warning("XcodeFiles: No version for device support: \(string), skipping")
            }
        }
        
        return nil
    }
    
    private func derivedDataEntry(from location: URL) -> DerivedDataFileEntry? {
        // drop last part that's the kind of id of a project
        let splitted = location.lastPathComponent.split(separator: "-", omittingEmptySubsequences: true).dropLast()
        
        // create project name
        let name = splitted.joined(separator: "-").replacingOccurrences(of: "_", with: " ") // replace all dashes with spaces
        
        // find project folder path
        let infoPath = location.appendingPathComponent("info.plist")
        
        if let projectInfoDict = NSDictionary(contentsOf: infoPath) {
            // try to get project folder path from .plist dictionary
            if let projectRealPath = projectInfoDict["WorkspacePath"] as? String {
                let projectRealPathUrl = URL(fileURLWithPath: projectRealPath)
                
                return DerivedDataFileEntry(projectName: name, pathUrl: projectRealPathUrl, selected: false)
            }
        }
        
        return nil
    }
    
    private func archiveFileEntry(from location: URL) -> ArchiveFileEntry? {
        guard location.pathExtension == "xcarchive" else {
            return nil
        }
        
        // open archive info.plist for more informations
        let projectName: String
        let bundleName: String
        let bundleVersion: Version
        let bundleBuild: String
        let archiveDate: Date
        
        let infoPath = location.appendingPathComponent("Info.plist")
        if let archiveInfoDict = NSDictionary(contentsOf: infoPath) {
            // project name
            if let name = archiveInfoDict["Name"] as? String {
                projectName = name
            } else {
                log.warning("XcodeFiles: Cannot get project name from archive: \(location.path)")
                return nil
            }
            
            // archive date
            if let date = archiveInfoDict["CreationDate"] as? Date {
                archiveDate = date
            } else {
                log.warning("XcodeFiles: Cannot get archive date from archive: \(location.path)")
                return nil
            }
            
            if let archiveProperties = archiveInfoDict["ApplicationProperties"] as? [String : Any] {
                // bundle name
                if let bundle = archiveProperties["CFBundleIdentifier"] as? String {
                    bundleName = bundle
                } else {
                    log.warning("XcodeFiles: Cannot get bundle name from archive: \(location.path)")
                    return nil
                }
                
                // version
                if let versionString = archiveProperties["CFBundleShortVersionString"] as? String, let version = Version(describing: versionString) {
                    bundleVersion = version
                } else {
                    log.warning("XcodeFiles: Cannot get bundle version from archive: \(location.path)")
                    return nil
                }
                
                // build
                if let build = archiveProperties["CFBundleVersion"] as? String {
                    bundleBuild = build
                } else {
                    log.warning("XcodeFiles: Cannot get bundle build from archive: \(location.path)")
                    return nil
                }
            } else {
                log.warning("XcodeFiles: Cannot get 'ApplicationProperties' from archive Info.plist file: \(location.path)")
                return nil
            }
        } else {
            log.warning("XcodeFiles: Cannot open Info.plist file from archive: \(location.path)")
            return nil
        }
        
        return ArchiveFileEntry(projectName: projectName,
                                bundleName: bundleName,
                                version: bundleVersion,
                                build: bundleBuild,
                                date: archiveDate,
                                location: location,
                                selected: false)
    }
    
    // MARK: Clearing items
    public func cleanAllEntries() {
        for location in locations.values {
            location.removeAllChildren()
            location.recalculateSize()
        }
    }
    
    // MARK: Updating required data
    public func updateCustomFolders(customDerivedDataFolder: URL?, customArchivesFolder: URL?) {
        // clear old security access
        self.customDerivedDataFolderUrl?.stopAccessingSecurityScopedResource()
        self.customArchivesFolderUrl?.stopAccessingSecurityScopedResource()
        
        // update folders
        self.customDerivedDataFolderUrl = customDerivedDataFolder
        self.customArchivesFolderUrl = customArchivesFolder
        
        // restart security scope access
        let _ = self.customDerivedDataFolderUrl?.startAccessingSecurityScopedResource()
        let _ = self.customArchivesFolderUrl?.startAccessingSecurityScopedResource()
    }
    
    // MARK: Scan files
    public func scanFiles(in locations: [Location]) {
        DispatchQueue.main.async { [weak self] in
            if let strongSelf = self {
                strongSelf.scanDelegate?.scanWillBegin(xcodeFiles: strongSelf)
            }
        }
        
        self.cleanAllEntries()
        
        for location in locations {
            self.scanFiles(in: location)
        }
        
        DispatchQueue.main.async { [weak self] in
            if let strongSelf = self {
                strongSelf.scanDelegate?.scanDidFinish(xcodeFiles: strongSelf)
            }
        }
    }
    
    private func scanFiles(in location: Location) {
        guard let entry = self.locations[location] else {
            precondition(self.locations.keys.contains(location), "❌ No entry found for location: \(location)")
            return
        }
        
        // remove previous entries
        entry.removeAllChildren()
        
        // scan and find files
        switch location {
            case .deviceSupport:
                entry.addChildren(items: self.scanDeviceSupportLocations())
            
            case .archives:
                entry.addChildren(items: self.scanArchivesLocations())
            
            case .derivedData:
                entry.addChildren(items: self.scanDerivedDataLocations())
        }
        
        // check for those files sizes
        entry.recalculateSize()
        
        // check for selections
        entry.recalculateSelection()
    }
    
    private func scanDeviceSupportLocations() -> [XcodeFileEntry] {
        let deviceSupportEntries = [
            (entry: XcodeFileEntry(label: "iOS", icon: .image(name: "Devices/iPadIcon"), selected: true), path: "iOS DeviceSupport"),
            (entry: XcodeFileEntry(label: "watchOS", icon: .image(name: "Devices/WatchIcon"), selected: true), path: "watchOS DeviceSupport"),
            (entry: XcodeFileEntry(label: "tvOS", icon: .image(name: "Devices/AppleTVIcon"), selected: true), path: "tvOS DeviceSupport")
        ]
                
        let xcodeLocation = self.userDeveloperFolderUrl.appendingPathComponent("Xcode")
        var entries: [XcodeFileEntry] = []
        for osEntry in deviceSupportEntries {
            let entryUrl = xcodeLocation.appendingPathComponent(osEntry.path)
            
            // scan for versions
            if let symbols = try? FileManager.default.contentsOfDirectory(at: entryUrl, includingPropertiesForKeys: nil) {
                var deviceSupportEntries = [DeviceSupportFileEntry]()
                for symbolUrl in symbols {
                    if let deviceSupportEntry = self.deviceSupportEntry(from: symbolUrl.lastPathComponent, osLabel: osEntry.entry.label) {
                        deviceSupportEntry.addPath(path: symbolUrl)
                        
                        deviceSupportEntries.append(deviceSupportEntry)
                    }
                }
                
                // sort
                deviceSupportEntries = deviceSupportEntries.sorted { (lhs, rhs) -> Bool in
                    lhs.version > rhs.version
                }
                
                // deselect first one (we usually will want those symbols)
                if let firstEntry = deviceSupportEntries.first {
                    firstEntry.deselectWithChildItems()
                }
                
                osEntry.entry.addChildren(items: deviceSupportEntries)
                
            } else {
                log.warning("XcodeFiles: Cannot check contents of '\(entryUrl)', skipping")
            }
            
            entries.append(osEntry.entry)
        }
        
        return entries
    }
    
    private func scanArchivesLocations() -> [XcodeFileEntry] {
        var archiveLocations = [URL]()
        archiveLocations.append(self.userDeveloperFolderUrl.appendingPathComponent("Xcode/Archives"))
        
        if let customArchivesLocation = self.customArchivesFolderUrl {
            if !archiveLocations.contains(customArchivesLocation) {
                archiveLocations.append(customArchivesLocation)
            }
        }
        
        // gather various projects, create entries for each of them
        var archiveInfos = [String : [ArchiveFileEntry]]()
        for archivesLocation in archiveLocations {
            if let datesFolders = try? FileManager.default.contentsOfDirectory(at: archivesLocation, includingPropertiesForKeys: nil) {
                for dateFolder in datesFolders {
                    if let xcarchives = try? FileManager.default.contentsOfDirectory(at: dateFolder, includingPropertiesForKeys: nil) {
                        for xcarchive in xcarchives {
                            if let xcarchiveEntry = self.archiveFileEntry(from: xcarchive) {
                                if archiveInfos.keys.contains(xcarchiveEntry.bundleName) {
                                    archiveInfos[xcarchiveEntry.bundleName]?.append(xcarchiveEntry)
                                } else {
                                    archiveInfos[xcarchiveEntry.bundleName] = [xcarchiveEntry]
                                }
                            }
                        }
                    }
                }
            }
        }
        
        // convert archive infos for project entries
        return archiveInfos.compactMap { (arg) -> XcodeFileEntry? in
            let (_, archiveEntries) = arg
            
            guard let projectName = archiveEntries.first?.projectName else {
                return nil
            }
            
            // root project
            let projectEntry = XcodeFileEntry(label: projectName, icon: .image(name: "XCArchive"), selected: false)
            
            // sort by version & build
            let projectArchiveEntries = archiveEntries.sorted { (lhs, rhs) -> Bool in
                if lhs.version == rhs.version {
                    return lhs.build > rhs.build
                } else {
                    return lhs.version > rhs.version
                }
                
            }
            
            projectEntry.addChildren(items: projectArchiveEntries)
            
            return projectEntry
        }
    }
    
    private func scanDerivedDataLocations() -> [XcodeFileEntry] {
        var derivedDataLocations = [URL]()
        derivedDataLocations.append(self.userDeveloperFolderUrl.appendingPathComponent("Xcode/DerivedData"))
        
        if let customDerivedDataLocation = self.customDerivedDataFolderUrl {
            if !derivedDataLocations.contains(customDerivedDataLocation) {
                derivedDataLocations.append(customDerivedDataLocation)
            }
        }
        
        // scan for derived data projects
        var results: [XcodeFileEntry] = []
        for derivedDataLocation in derivedDataLocations {
            if let projectsFolders = try? FileManager.default.contentsOfDirectory(at: derivedDataLocation, includingPropertiesForKeys: nil) {
                for projectFolder in projectsFolders {
                    // ignore "ModuleCache" folder
                    if projectFolder.lastPathComponent == "ModuleCache" {
                        continue
                    }
                    
                    if let projectEntry = self.derivedDataEntry(from: projectFolder) {
                        projectEntry.addPath(path: projectFolder)
                        
                        results.append(projectEntry)
                    }
                }
            }
        }
        
        return results
    }
    
    // MARK: Deleting files
    public func deleteSelectedEntries(dryRun: Bool) {
        DispatchQueue.main.async { [weak self] in
            if let strongSelf = self {
                strongSelf.deleteDelegate?.deleteWillBegin(xcodeFiles: strongSelf)
            }
        }
        
        // gather a list of items to delete
        typealias DeletionItem = (location: String, label: String, path: URL)
        var itemsToDelete = [DeletionItem]()
        
        for location in self.locations.values where location.isSelected {
            var searchStack = Stack<XcodeFileEntry>()
            searchStack.push(location)
            
            // simple iterative pre-order tree search algorithm
            while !searchStack.isEmpty {
                if let currentEntry = searchStack.pop() {
                    if currentEntry.isSelected && currentEntry.paths.count > 0 {
                        let pathsFromNode = currentEntry.paths.map { DeletionItem(location: location.label, label: currentEntry.label, path: $0) }
                        itemsToDelete.append(contentsOf: pathsFromNode)
                    }
                    
                    for nextEntry in currentEntry.items {
                        searchStack.push(nextEntry)
                    }
                }
            }
        }
        
        // perform deletions
        let dryRunInfo = dryRun ? "[DRY RUN!]" : String()
        
        let itemsCount = itemsToDelete.count
        var ordinal = 0
        for itemToDelete in itemsToDelete {
            ordinal += 1

            DispatchQueue.main.async { [weak self] in
                if let strongSelf = self {
                    strongSelf.deleteDelegate?.deleteInProgress(xcodeFiles: strongSelf,
                                                                location: itemToDelete.location,
                                                                label: itemToDelete.label,
                                                                url: itemToDelete.path,
                                                                current: ordinal,
                                                                total: itemsCount)
                }
            }
            
            log.info("Deleting \(dryRunInfo): \(itemToDelete.location): \(itemToDelete.label) (\(itemToDelete.path.path))")
            
            if dryRun {
                Thread.sleep(forTimeInterval: 0.15)
            } else {
                do {
                    try FileManager.default.removeItem(at: itemToDelete.path)
                } catch(let error) {
                    DispatchQueue.main.async { [weak self] in
                        if let strongSelf = self {
                            strongSelf.deleteDelegate?.deleteItemFailed(xcodeFiles: strongSelf,
                                                                        error: error,
                                                                        location: itemToDelete.location,
                                                                        label: itemToDelete.label,
                                                                        url: itemToDelete.path)
                        }
                    }
                }
            }
        }
        
        DispatchQueue.main.async { [weak self] in
            if let strongSelf = self {
                strongSelf.deleteDelegate?.deleteDidFinish(xcodeFiles: strongSelf)
            }
        }
    }
}
