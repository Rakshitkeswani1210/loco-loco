using System.Buffers.Binary;
using System.IO.Compression;

namespace LocoLoco.Art;

public static class Png
{
    static readonly uint[] Crc = MakeCrc();

    static uint[] MakeCrc()
    {
        var t = new uint[256];
        for (uint n = 0; n < 256; n++)
        {
            uint c = n;
            for (int k = 0; k < 8; k++) c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
            t[n] = c;
        }
        return t;
    }

    /// <summary>An 8-bit RGBA PNG from straight-alpha pixels, rows top to bottom.</summary>
    public static byte[] Encode(int width, int height, byte[] rgba)
    {
        using var raw = new MemoryStream();
        using (var z = new ZLibStream(raw, CompressionLevel.SmallestSize, leaveOpen: true))
        {
            for (int y = 0; y < height; y++)
            {
                z.WriteByte(0);
                z.Write(rgba, y * width * 4, width * 4);
            }
        }

        using var o = new MemoryStream();
        o.Write([0x89, (byte)'P', (byte)'N', (byte)'G', 0x0D, 0x0A, 0x1A, 0x0A]);
        var ihdr = new byte[13];
        BinaryPrimitives.WriteInt32BigEndian(ihdr, width);
        BinaryPrimitives.WriteInt32BigEndian(ihdr.AsSpan(4), height);
        ihdr[8] = 8;
        ihdr[9] = 6;
        Chunk(o, "IHDR", ihdr);
        Chunk(o, "IDAT", raw.ToArray());
        Chunk(o, "IEND", []);
        return o.ToArray();
    }

    static void Chunk(Stream o, string type, byte[] data)
    {
        Span<byte> b4 = stackalloc byte[4];
        BinaryPrimitives.WriteInt32BigEndian(b4, data.Length);
        o.Write(b4);
        var head = System.Text.Encoding.ASCII.GetBytes(type);
        o.Write(head);
        o.Write(data);
        uint c = 0xFFFFFFFF;
        foreach (var x in head) c = Crc[(c ^ x) & 0xFF] ^ (c >> 8);
        foreach (var x in data) c = Crc[(c ^ x) & 0xFF] ^ (c >> 8);
        BinaryPrimitives.WriteUInt32BigEndian(b4, c ^ 0xFFFFFFFF);
        o.Write(b4);
    }
}

public static class Ico
{
    /// <summary>An .ico with one PNG image per size, which Windows reads at every size since Vista.</summary>
    public static byte[] Encode(IReadOnlyList<(int Size, byte[] Png)> images)
    {
        using var o = new MemoryStream();
        using var w = new BinaryWriter(o);
        w.Write((ushort)0);
        w.Write((ushort)1);
        w.Write((ushort)images.Count);
        int offset = 6 + 16 * images.Count;
        foreach (var (size, png) in images)
        {
            w.Write((byte)(size >= 256 ? 0 : size));
            w.Write((byte)(size >= 256 ? 0 : size));
            w.Write((byte)0);
            w.Write((byte)0);
            w.Write((ushort)1);
            w.Write((ushort)32);
            w.Write(png.Length);
            w.Write(offset);
            offset += png.Length;
        }
        foreach (var (_, png) in images) w.Write(png);
        w.Flush();
        return o.ToArray();
    }
}
