// Reads the numbers behind the vitals badge, the way Activity Monitor counts them,
// and prints them on one line:
//
//   vitalsinfo  ->  <cpu busy ticks> <cpu total ticks> <memory used bytes> <memory total bytes>
//
// CPU is reported as ticks since boot, not a percentage: a percentage needs two
// samples, and plugins/vitals.sh keeps the previous one between its polls, so a
// run costs no waiting. Memory used is Activity Monitor's figure: app memory
// (anonymous pages less purgeable), wired, and compressed.
//
// Usage: swiftc -O vitalsinfo.swift -o vitalsinfo

import Darwin
import Foundation

var cpu = host_cpu_load_info()
var cpuCount = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
let cpuResult = withUnsafeMutablePointer(to: &cpu) {
    $0.withMemoryRebound(to: integer_t.self, capacity: Int(cpuCount)) {
        host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &cpuCount)
    }
}
var vm = vm_statistics64()
var vmCount = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
let vmResult = withUnsafeMutablePointer(to: &vm) {
    $0.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) {
        host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &vmCount)
    }
}
guard cpuResult == KERN_SUCCESS, vmResult == KERN_SUCCESS else {
    FileHandle.standardError.write(Data("vitalsinfo: host_statistics failed\n".utf8)); exit(1)
}

let ticks = cpu.cpu_ticks  // user, system, idle, nice
let busy = UInt64(ticks.0) + UInt64(ticks.1) + UInt64(ticks.3)
let total = busy + UInt64(ticks.2)
var page: vm_size_t = 0
host_page_size(mach_host_self(), &page)
let appPages = UInt64(vm.internal_page_count) - UInt64(vm.purgeable_count)
let used = (appPages + UInt64(vm.wire_count) + UInt64(vm.compressor_page_count)) * UInt64(page)
print(busy, total, used, ProcessInfo.processInfo.physicalMemory)
