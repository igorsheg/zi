// @ts-nocheck -- bun:ffi kernel32 bindings are Windows-only and pointer-typed loosely.
/**
 * Windows Job Object helpers. kernel32 is opened only when the Windows process scope is created.
 */

import { dlopen } from "bun:ffi"

export type WindowsHandle = bigint | number

export type WindowsJobNative = {
  createJob(): WindowsHandle
  configureKillOnClose(handle: WindowsHandle): void
  assignPid(handle: WindowsHandle, pid: number): void
  close(handle: WindowsHandle): void
}

export function loadWindowsJobNative(): WindowsJobNative {
  if (process.platform !== "win32") throw new Error("Windows job API is only available on win32")

  const kernel32 = dlopen("kernel32.dll", {
    CreateJobObjectW: { args: ["ptr", "ptr"], returns: "ptr" },
    SetInformationJobObject: { args: ["ptr", "i32", "ptr", "u32"], returns: "i32" },
    AssignProcessToJobObject: { args: ["ptr", "ptr"], returns: "i32" },
    OpenProcess: { args: ["u32", "i32", "u32"], returns: "ptr" },
    CloseHandle: { args: ["ptr"], returns: "i32" },
    GetLastError: { args: [], returns: "u32" }
  })

  const pointerWidth = process.arch === "x64" || process.arch === "arm64" ? 64 : 32
  const nullHandle = pointerWidth === 64 ? 0n : 0
  const extendedLimitInformationSize = pointerWidth === 64 ? 144 : 72
  const limitFlagsOffset = 16
  const lastError = () => new Error(`Win32 job call failed with error ${kernel32.symbols.GetLastError()}`)

  return {
    createJob() {
      const handle = kernel32.symbols.CreateJobObjectW(null, null)
      if (handle === nullHandle) throw lastError()
      return handle
    },
    configureKillOnClose(handle) {
      const info = Buffer.alloc(extendedLimitInformationSize)
      // JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
      info.writeUInt32LE(0x2000, limitFlagsOffset)
      if (kernel32.symbols.SetInformationJobObject(handle, 9, info, info.byteLength) === 0) throw lastError()
    },
    assignPid(handle, pid) {
      // PROCESS_SET_QUOTA | PROCESS_TERMINATE
      const processHandle = kernel32.symbols.OpenProcess(0x0100 | 0x0001, 0, pid)
      if (processHandle === nullHandle) throw lastError()
      try {
        if (kernel32.symbols.AssignProcessToJobObject(handle, processHandle) === 0) throw lastError()
      } finally {
        kernel32.symbols.CloseHandle(processHandle)
      }
    },
    close(handle) {
      kernel32.symbols.CloseHandle(handle)
    }
  }
}
