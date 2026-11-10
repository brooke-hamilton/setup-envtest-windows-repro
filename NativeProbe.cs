using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

public static class NativeProbe
{
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr LoadLibraryEx(string path, IntPtr file, uint flags);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool FreeLibrary(IntPtr module);
    delegate bool ResourceCallback(IntPtr module, IntPtr type, IntPtr name, IntPtr context);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool EnumResourceNames(IntPtr module, IntPtr type, ResourceCallback callback, IntPtr context);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr FindResource(IntPtr module, IntPtr name, IntPtr type);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern uint SizeofResource(IntPtr module, IntPtr resource);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern IntPtr LoadResource(IntPtr module, IntPtr resource);
    [DllImport("kernel32.dll")]
    static extern IntPtr LockResource(IntPtr resource);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr BeginUpdateResource(string path, bool deleteExistingResources);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool UpdateResource(IntPtr update, IntPtr type, IntPtr name, ushort language, byte[] data, uint size);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool EndUpdateResource(IntPtr update, bool discard);
    [DllImport("advapi32.dll", SetLastError = true)]
    static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
    [DllImport("advapi32.dll", SetLastError = true)]
    static extern bool GetTokenInformation(IntPtr token, int informationClass, out int value, int size, out int returned);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool CloseHandle(IntPtr handle);

    public static bool IsElevated()
    {
        IntPtr token;
        using (var process = System.Diagnostics.Process.GetCurrentProcess())
        {
            if (!OpenProcessToken(process.Handle, 8, out token))
                throw new Win32Exception();
        }
        try
        {
            int value, returned;
            if (!GetTokenInformation(token, 20, out value, 4, out returned))
                throw new Win32Exception();
            return value != 0;
        }
        finally { CloseHandle(token); }
    }

    public static string Machine(string path)
    {
        using (var reader = new BinaryReader(File.OpenRead(path)))
        {
            if (reader.ReadUInt16() != 0x5a4d)
                throw new InvalidDataException("Missing DOS signature.");
            reader.BaseStream.Position = 0x3c;
            int offset = reader.ReadInt32();
            reader.BaseStream.Position = offset;
            if (reader.ReadUInt32() != 0x4550)
                throw new InvalidDataException("Missing PE signature.");
            ushort machine = reader.ReadUInt16();
            switch (machine)
            {
                case 0xaa64: return "ARM64 (0xAA64)";
                case 0x8664: return "AMD64 (0x8664)";
                case 0x014c: return "I386 (0x014C)";
                default: return "Unknown (0x" + machine.ToString("X4") + ")";
            }
        }
    }

    public static string[] Manifests(string path)
    {
        // Map as data, never execute the binary or its initialization code.
        IntPtr module = LoadLibraryEx(path, IntPtr.Zero, 0x22);
        if (module == IntPtr.Zero) throw new Win32Exception();
        try
        {
            var manifests = new List<string>();
            ResourceCallback callback = (m, type, name, context) =>
            {
                IntPtr resource = FindResource(m, name, type);
                if (resource == IntPtr.Zero) throw new Win32Exception();
                uint size = SizeofResource(m, resource);
                IntPtr loaded = LoadResource(m, resource);
                if (loaded == IntPtr.Zero) throw new Win32Exception();
                IntPtr data = LockResource(loaded);
                if (data == IntPtr.Zero) throw new Win32Exception();
                byte[] bytes = new byte[checked((int)size)];
                Marshal.Copy(data, bytes, 0, bytes.Length);
                using (var reader = new StreamReader(new MemoryStream(bytes), Encoding.UTF8, true))
                    manifests.Add(reader.ReadToEnd());
                return true;
            };
            if (!EnumResourceNames(module, new IntPtr(24), callback, IntPtr.Zero))
            {
                int error = Marshal.GetLastWin32Error();
                // A missing resource directory or RT_MANIFEST type means no manifest.
                if (error != 1812 && error != 1813)
                    throw new Win32Exception(error);
            }
            return manifests.ToArray();
        }
        finally { FreeLibrary(module); }
    }

    public static void AddAsInvokerManifest(string path)
    {
        if (Manifests(path).Length != 0)
            throw new InvalidOperationException("Refusing to overwrite an existing manifest.");
        const string xml = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>" +
            "<assembly xmlns=\"urn:schemas-microsoft-com:asm.v1\" manifestVersion=\"1.0\">" +
            "<trustInfo xmlns=\"urn:schemas-microsoft-com:asm.v3\"><security><requestedPrivileges>" +
            "<requestedExecutionLevel level=\"asInvoker\" uiAccess=\"false\"/>" +
            "</requestedPrivileges></security></trustInfo></assembly>";
        byte[] bytes = Encoding.UTF8.GetBytes(xml);
        IntPtr update = BeginUpdateResource(path, false);
        if (update == IntPtr.Zero) throw new Win32Exception();
        if (!UpdateResource(update, new IntPtr(24), new IntPtr(1), 0, bytes, (uint)bytes.Length))
        {
            int error = Marshal.GetLastWin32Error();
            EndUpdateResource(update, true);
            throw new Win32Exception(error);
        }
        if (!EndUpdateResource(update, false)) throw new Win32Exception();
    }
}
