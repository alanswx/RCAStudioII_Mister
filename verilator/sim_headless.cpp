// ---------------------------------------------------------------------------
// Headless Verilator harness for the RCA Studio II MiSTer core.
//
// No SDL / ImGui / OpenGL: this builds and runs anywhere, which makes it
// usable for scripted regression testing. It can
//   * load a BIOS and a cartridge over the simulated HPS ioctl bus
//   * run for a given number of video frames
//   * write a PNG / PPM / ASCII screenshot at chosen frames
//   * dump CPU + video + memory state at chosen frames
//   * inject keypad presses at chosen frames
//
// Build:  make headless          Run: ./obj_dir_headless/Vtop --help
// ---------------------------------------------------------------------------

#include <verilated.h>
#include "Vtop.h"
#include "Vtop___024root.h"

#include <zlib.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <string>
#include <vector>
#include <set>
#include <map>

// ---------------------------------------------------------------------------
// Convenience accessors into the verilated design.
// --public-flat-rw exposes every internal signal on the root scope.
// ---------------------------------------------------------------------------
#define RS(sig)   (top->rootp->top__DOT__rcastudio__DOT__##sig)
#define CPU(sig)  (top->rootp->top__DOT__rcastudio__DOT__cdp1802__DOT__##sig)
#define PIX(sig)  (top->rootp->top__DOT__rcastudio__DOT__pixie_video__DOT__cdp1861__DOT__##sig)
#define DPRAM     (top->rootp->top__DOT__rcastudio__DOT__dpram__DOT__mem)

static Vtop* top = nullptr;
static vluint64_t main_time = 0;
double sc_time_stamp() { return (double)main_time; }

// ---------------------------------------------------------------------------
// PNG writer (zlib, 8-bit RGB, no external image library)
// ---------------------------------------------------------------------------
static void put_be32(std::vector<uint8_t>& v, uint32_t x) {
    v.push_back((x >> 24) & 0xff); v.push_back((x >> 16) & 0xff);
    v.push_back((x >> 8) & 0xff);  v.push_back(x & 0xff);
}

static void png_chunk(FILE* f, const char* type, const uint8_t* data, size_t len) {
    std::vector<uint8_t> hdr;
    put_be32(hdr, (uint32_t)len);
    fwrite(hdr.data(), 1, hdr.size(), f);
    fwrite(type, 1, 4, f);
    if (len) fwrite(data, 1, len, f);
    uLong crc = crc32(0L, Z_NULL, 0);
    crc = crc32(crc, (const Bytef*)type, 4);
    if (len) crc = crc32(crc, (const Bytef*)data, (uInt)len);
    std::vector<uint8_t> tail;
    put_be32(tail, (uint32_t)crc);
    fwrite(tail.data(), 1, tail.size(), f);
}

// rgb is w*h*3 bytes
static bool write_png(const std::string& path, int w, int h, const std::vector<uint8_t>& rgb) {
    FILE* f = fopen(path.c_str(), "wb");
    if (!f) { fprintf(stderr, "error: cannot write %s\n", path.c_str()); return false; }

    static const uint8_t sig[8] = { 137, 'P', 'N', 'G', '\r', '\n', 26, '\n' };
    fwrite(sig, 1, 8, f);

    std::vector<uint8_t> ihdr;
    put_be32(ihdr, (uint32_t)w);
    put_be32(ihdr, (uint32_t)h);
    ihdr.push_back(8);              // bit depth
    ihdr.push_back(2);              // colour type: truecolour RGB
    ihdr.push_back(0);              // deflate
    ihdr.push_back(0);              // adaptive filtering
    ihdr.push_back(0);              // no interlace
    png_chunk(f, "IHDR", ihdr.data(), ihdr.size());

    // Raw scanlines, each prefixed with filter type 0.
    std::vector<uint8_t> raw;
    raw.reserve((size_t)h * (1 + (size_t)w * 3));
    for (int y = 0; y < h; y++) {
        raw.push_back(0);
        raw.insert(raw.end(), rgb.begin() + (size_t)y * w * 3,
                              rgb.begin() + (size_t)(y + 1) * w * 3);
    }

    uLongf clen = compressBound((uLong)raw.size());
    std::vector<uint8_t> comp(clen);
    if (compress2(comp.data(), &clen, raw.data(), (uLong)raw.size(), 9) != Z_OK) {
        fprintf(stderr, "error: zlib compress failed\n"); fclose(f); return false;
    }
    png_chunk(f, "IDAT", comp.data(), clen);
    png_chunk(f, "IEND", nullptr, 0);
    fclose(f);
    return true;
}

static bool write_ppm(const std::string& path, int w, int h, const std::vector<uint8_t>& rgb) {
    FILE* f = fopen(path.c_str(), "wb");
    if (!f) { fprintf(stderr, "error: cannot write %s\n", path.c_str()); return false; }
    fprintf(f, "P6\n%d %d\n255\n", w, h);
    fwrite(rgb.data(), 1, rgb.size(), f);
    fclose(f);
    return true;
}

// ---------------------------------------------------------------------------
// Frame capture
// ---------------------------------------------------------------------------
static const int MAX_W = 2048;
static const int MAX_H = 1024;

struct FrameGrabber {
    std::vector<uint8_t> pix;   // MAX_W * MAX_H, 0 or 1
    int col = 0, line = 0;
    int width = 0, height = 0;  // active extents of the frame being built
    int last_width = 0, last_height = 0;
    bool prev_vs = false, prev_hs = false;
    long frame = 0;
    bool complete = false;      // a full frame has been captured at least once

    FrameGrabber() : pix((size_t)MAX_W * MAX_H, 0) {}

    // Returns true on the clock where a frame boundary was crossed.
    bool clock(bool vs, bool hs, bool de, bool video) {
        bool boundary = false;

        if (vs && !prev_vs) {
            last_width = width; last_height = height;
            if (last_width > 0 && last_height > 0) complete = true;
            frame++;
            boundary = true;
        }

        if (hs && !prev_hs) {
            if (col > 0) line++;
            col = 0;
        }

        if (boundary) { line = 0; col = 0; width = 0; height = 0; }

        if (de && line < MAX_H && col < MAX_W) {
            pix[(size_t)line * MAX_W + col] = video ? 1 : 0;
            col++;
            if (col > width) width = col;
            if (line + 1 > height) height = line + 1;
        }

        prev_vs = vs; prev_hs = hs;
        return boundary;
    }

    // Snapshot of the frame that just finished, as RGB.
    void to_rgb(std::vector<uint8_t>& out, int& w, int& h, int scale) const {
        w = last_width * scale;
        h = last_height * scale;
        out.assign((size_t)w * h * 3, 0);
        for (int y = 0; y < last_height; y++) {
            for (int x = 0; x < last_width; x++) {
                uint8_t v = pix[(size_t)y * MAX_W + x] ? 0xFF : 0x00;
                for (int sy = 0; sy < scale; sy++) {
                    for (int sx = 0; sx < scale; sx++) {
                        size_t o = (((size_t)y * scale + sy) * w + ((size_t)x * scale + sx)) * 3;
                        out[o] = out[o + 1] = out[o + 2] = v;
                    }
                }
            }
        }
    }

    void to_ascii(FILE* f) const {
        fprintf(f, "    +");
        for (int x = 0; x < last_width; x++) fputc('-', f);
        fprintf(f, "+\n");
        for (int y = 0; y < last_height; y++) {
            fprintf(f, "%3d |", y);
            for (int x = 0; x < last_width; x++)
                fputc(pix[(size_t)y * MAX_W + x] ? '#' : ' ', f);
            fprintf(f, "|\n");
        }
        fprintf(f, "    +");
        for (int x = 0; x < last_width; x++) fputc('-', f);
        fprintf(f, "+\n");
    }

    uint32_t hash() const {
        uint32_t h = 2166136261u;   // FNV-1a
        for (int y = 0; y < last_height; y++)
            for (int x = 0; x < last_width; x++)
                h = (h ^ pix[(size_t)y * MAX_W + x]) * 16777619u;
        return h;
    }

    bool blank() const {
        for (int y = 0; y < last_height; y++)
            for (int x = 0; x < last_width; x++)
                if (pix[(size_t)y * MAX_W + x]) return false;
        return true;
    }
};

// ---------------------------------------------------------------------------
// ioctl download driver (stands in for the HPS)
// ---------------------------------------------------------------------------
struct Download {
    std::string path;
    int index;
};

struct IoctlDriver {
    std::vector<Download> queue;
    size_t qpos = 0;
    std::vector<uint8_t> data;
    size_t pos = 0;
    int gap = 0;
    bool active = false;
    bool finished = false;

    void add(const std::string& path, int index) { queue.push_back({ path, index }); }

    bool load_next() {
        while (qpos < queue.size()) {
            const Download& d = queue[qpos++];
            FILE* f = fopen(d.path.c_str(), "rb");
            if (!f) { fprintf(stderr, "error: cannot open %s\n", d.path.c_str()); exit(2); }
            fseek(f, 0, SEEK_END);
            long n = ftell(f);
            fseek(f, 0, SEEK_SET);
            data.resize((size_t)n);
            if (n > 0 && fread(data.data(), 1, (size_t)n, f) != (size_t)n) {
                fprintf(stderr, "error: short read on %s\n", d.path.c_str()); exit(2);
            }
            fclose(f);
            pos = 0;
            active = true;
            top->ioctl_index = (uint8_t)d.index;
            fprintf(stderr, "[ioctl] %s -> index %d (%ld bytes)\n", d.path.c_str(), d.index, n);
            return true;
        }
        finished = true;
        return false;
    }

    // Called immediately before each rising-edge eval.
    void tick() {
        if (!active) {
            top->ioctl_download = 0;
            top->ioctl_wr = 0;
            if (gap > 0) { gap--; return; }
            if (!finished) load_next();
            return;
        }
        if (pos < data.size()) {
            top->ioctl_download = 1;
            top->ioctl_wr = 1;
            top->ioctl_addr = (uint32_t)pos;
            top->ioctl_dout = data[pos];
            pos++;
        } else {
            top->ioctl_download = 0;
            top->ioctl_wr = 0;
            active = false;
            gap = 256;   // let reset settle between downloads
        }
    }
};

// ---------------------------------------------------------------------------
// Keypad injection
// ---------------------------------------------------------------------------
// PS/2 set-2 scancodes, matching the table in rtl/rcastudioii.sv.
static const uint8_t PS2_A[10] = { 0x22,0x16,0x1E,0x26,0x15,0x1D,0x24,0x1C,0x1B,0x23 };   // keypad A, 3x4 layout: X=0, 123 / QWE / ASD
static const uint8_t PS2_B[10] = { 0x41,0x3D,0x3E,0x46,0x3C,0x43,0x44,0x3B,0x42,0x4B };   // keypad B, 3x4 layout: ,=0, 789 / UIO / JKL

struct KeyEvent {
    long frame;
    int  hold;      // frames to hold
    uint8_t code;
    bool pressed;   // filled in during scheduling
};

// ---------------------------------------------------------------------------
// State dump
// ---------------------------------------------------------------------------
static const char* state_name(int s) {
    switch (s) {
        case 0: return "RESET";  case 1: return "FETCH";     case 2: return "EXECUTE";
        case 3: return "EXECUTE2"; case 4: return "BRANCH2"; case 5: return "BRANCH3";
        case 6: return "SKIP";   case 7: return "DMA_IN";    case 8: return "DMA_OUT";
        case 9: return "INTERRUPT"; default: return "?";
    }
}
static const char* sc_name(int s) {
    switch (s) {
        case 0: return "S0 fetch"; case 1: return "S1 execute";
        case 2: return "S2 dma";   case 3: return "S3 interrupt"; default: return "?";
    }
}

static void dump_state(FILE* f, long frame, const FrameGrabber& fg, bool with_vram) {
    fprintf(f, "===== frame %ld  (sim time %llu) =====\n", frame,
            (unsigned long long)main_time);

    fprintf(f, "-- CDP1802 --\n");
    fprintf(f, "  state   %-10s (state_n %s)\n", state_name(CPU(state)), state_name(CPU(state_n)));
    fprintf(f, "  SC      %d (%s)   IE %d   Q %d\n", CPU(SC), sc_name(CPU(SC)), CPU(IE), CPU(Q));
    fprintf(f, "  I:N     %X%X       D %02X  DF %d  T %02X  B %02X\n",
            CPU(I), CPU(N), CPU(D), CPU(DF), CPU(T), CPU(B));
    fprintf(f, "  P %X  X %X   PC=R[%X]=%04X\n", CPU(P), CPU(X), CPU(P), CPU(R)[CPU(P)]);
    fprintf(f, "  EF %X (EF4 %d EF3 %d EF2 %d EF1 %d)  INT_N %d  DMAO_req %d\n",
            CPU(EF), (CPU(EF) >> 3) & 1, (CPU(EF) >> 2) & 1,
            (CPU(EF) >> 1) & 1, CPU(EF) & 1, CPU(INT_N), CPU(dma_out_req));
    fprintf(f, "  bus     a=%04X q=%02X d=%02X rd=%d wr=%d\n",
            CPU(ram_a), CPU(ram_q), CPU(ram_d), CPU(ram_rd), CPU(ram_wr));
    fprintf(f, "  io      n=%d inp=%d out=%d   unsupported=%d\n",
            CPU(io_n), CPU(io_inp), CPU(io_out), CPU(unsupported));
    for (int i = 0; i < 16; i++) {
        if (i % 8 == 0) fprintf(f, "  R%X-R%X  ", i, i + 7);
        fprintf(f, "%04X ", CPU(R)[i]);
        if (i % 8 == 7) fprintf(f, "\n");
    }

    fprintf(f, "-- Cartridge mapping --\n");
    {
        static const char* pn[] = {"NONE","CROSS","PADDLE","SPACEWAR","FREEWAY","BOWLING","BASEBALL"};
        int pr = top->rootp->top__DOT__rcastudio__DOT__profile;
        fprintf(f, "  cart CRC16 %04X  ->  profile %d (%s)\n",
                top->rootp->top__DOT__rcastudio__DOT__cart_crc, pr,
                (pr >= 0 && pr < 7) ? pn[pr] : "?");
    }
    fprintf(f, "-- Pixie / video --\n");
    fprintf(f, "  display_enabled %d  dma_cnt %d  vcount %d  hcount %d\n",
            PIX(display_enabled), PIX(dma_cnt), PIX(vcount), PIX(hcount));
    fprintf(f, "  INT %d  DMAO %d  EFx %d   HS %d VS %d HB %d VB %d DE %d\n",
            RS(INT), RS(DMAO), RS(EFx),
            top->VGA_HS, top->VGA_VS, top->VGA_HB, top->VGA_VB, top->VGA_DE);
    fprintf(f, "  frame %dx%d  hash %08X  %s\n",
            fg.last_width, fg.last_height, fg.hash(), fg.blank() ? "BLANK" : "has content");

    fprintf(f, "-- Input --\n");
    fprintf(f, "  keylatch %X  playerA %03X  playerB %03X\n",
            RS(keylatch), RS(playerA), RS(playerB));

    if (with_vram) {
        fprintf(f, "-- Display RAM $0900-$09FF --\n");
        for (int r = 0; r < 256; r += 16) {
            fprintf(f, "  %04X: ", 0x900 + r);
            for (int c = 0; c < 16; c++) fprintf(f, "%02X ", DPRAM[0x900 + r + c]);
            fprintf(f, "\n");
        }
        fprintf(f, "-- System RAM $0800-$08FF --\n");
        for (int r = 0; r < 256; r += 16) {
            fprintf(f, "  %04X: ", 0x800 + r);
            for (int c = 0; c < 16; c++) fprintf(f, "%02X ", DPRAM[0x800 + r + c]);
            fprintf(f, "\n");
        }
    }
    fprintf(f, "\n");
}

// ---------------------------------------------------------------------------
static void usage(const char* argv0) {
    printf(
"Headless Verilator sim for the RCA Studio II MiSTer core.\n"
"\n"
"Usage: %s [options]\n"
"\n"
"  Software\n"
"    --bios FILE          BIOS image, ioctl index 0   (default ../rom/studio2.rom)\n"
"    --cart FILE          cartridge image, ioctl index 1 (raw .bin, loads at $0400)\n"
"\n"
"  Run length\n"
"    --frames N           stop after N video frames (default 300)\n"
"    --max-cycles N       hard cycle cap (default 400000000)\n"
"\n"
"  Screenshots\n"
"    --shot N[,N...]      capture at these frame numbers (repeatable)\n"
"    --shot-every N       capture every N frames\n"
"    --shot-last          capture the final frame\n"
"    --outdir DIR         output directory (default ./out)\n"
"    --prefix NAME        filename prefix (default from cart/bios name)\n"
"    --scale N            pixel scale for PNG output (default 4)\n"
"    --ppm                also write .ppm alongside the .png\n"
"    --ascii              also print the frame as ASCII art\n"
"\n"
"  State dumps\n"
"    --dump N[,N...]      dump CPU/video state at these frames (repeatable)\n"
"    --dump-every N       dump every N frames\n"
"    --vram               include $0800-$09FF hexdumps in state dumps\n"
"    --dump-file FILE     write dumps here instead of stdout\n"
"\n"
"  Input\n"
"    --joy-map N          OSD joystick override: 0 auto, 1 cross, 2 paddle,\n"
"                         3 spacewar, 4 freeway, 5 bowling, 6 baseball, 7 homebrew\n"
"    --joy MASK@F[:H]     drive joystick 0 with MASK (bit0 right, 1 left, 2 down,\n"
"                         3 up, 4 fire, 5 extra, 6 start, 17:8 A0..A9,\n"
"                         27:18 B0..B9) at frame F for H frames.\n"
"    --joy2 MASK@F[:H]    same, joystick 1\n"
"    --players N          OSD Players setting: 0 auto, 1 one player, 2 two\n"
"    --press KEY@F[:H]    press KEY at frame F, hold H frames (default 4).\n"
"                         KEY is a0..a9 (player A) or b0..b9 (player B),\n"
"                         or a raw hex PS/2 scancode like 0x16.\n"
"\n"
"  Tracing\n"
"    --trace-cpu N        log the first N instructions executed (PC, opcode, regs)\n"
"    --trace-from F       only start the CPU trace at frame F\n"
"\n"
"  Misc\n"
"    --trace-q            log every Q (beeper) edge with its frame number\n"
"    --frame-log          print one line per frame (frame, size, hash)\n"
"    --quiet              suppress per-frame progress\n"
"    --help\n", argv0);
}

static void parse_list(const char* s, std::set<long>& out) {
    const char* p = s;
    while (*p) {
        char* end;
        long v = strtol(p, &end, 10);
        if (end == p) break;
        out.insert(v);
        p = end;
        while (*p == ',' || *p == ' ') p++;
    }
}

int main(int argc, char** argv) {
    std::string bios = "../rom/studio2.rom";
    std::string cart;
    std::string outdir = "out";
    std::string prefix;
    std::string dumpfile;
    long frames = 300;
    long max_cycles = 400000000L;
    int  scale = 4;
    int  shot_every = 0, dump_every = 0;
    bool want_ppm = false, want_ascii = false, want_vram = false;
    bool shot_last = false, frame_log = false, quiet = false;
    long trace_cpu = 0, trace_from = 0;
    bool trace_q = false;
    uint32_t joy_mask = 0; long joy_from = -1, joy_to = -1;
    uint32_t joy2_mask = 0; long joy2_from = -1, joy2_to = -1;
    uint8_t  joy_override = 0;   // applied once top exists
    uint8_t  players_mode = 0;
    // Q gates the Studio II's beeper; track its edges so the core can be compared
    // against the reference emulator's Q even though AUDIO_L/R are still tied off.
    bool q_prev = false; long q_edges = 0, q_on_frames = 0; long q_last_chg = 0;
    bool a_prev = false; long a_edges = 0;   // beeper output transitions
    std::set<long> shots, dumps;
    std::vector<KeyEvent> keys;

    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        auto next = [&](const char* what) -> const char* {
            if (i + 1 >= argc) { fprintf(stderr, "error: %s needs an argument\n", what); exit(1); }
            return argv[++i];
        };
        if      (a == "--help" || a == "-h") { usage(argv[0]); return 0; }
        else if (a == "--bios")       bios = next("--bios");
        else if (a == "--cart")       cart = next("--cart");
        else if (a == "--outdir")     outdir = next("--outdir");
        else if (a == "--prefix")     prefix = next("--prefix");
        else if (a == "--dump-file")  dumpfile = next("--dump-file");
        else if (a == "--frames")     frames = atol(next("--frames"));
        else if (a == "--max-cycles") max_cycles = atol(next("--max-cycles"));
        else if (a == "--scale")      scale = atoi(next("--scale"));
        else if (a == "--shot")       parse_list(next("--shot"), shots);
        else if (a == "--dump")       parse_list(next("--dump"), dumps);
        else if (a == "--trace-cpu")  trace_cpu = atol(next("--trace-cpu"));
        else if (a == "--trace-from") trace_from = atol(next("--trace-from"));
        else if (a == "--shot-every") shot_every = atoi(next("--shot-every"));
        else if (a == "--dump-every") dump_every = atoi(next("--dump-every"));
        else if (a == "--shot-last")  shot_last = true;
        else if (a == "--ppm")        want_ppm = true;
        else if (a == "--ascii")      want_ascii = true;
        else if (a == "--vram")       want_vram = true;
        else if (a == "--joy") {
            std::string t = next("--joy");
            size_t at = t.find('@'); if (at == std::string::npos) { fprintf(stderr,"error: --joy needs MASK@FRAME\n"); exit(1); }
            int hold = 4; std::string rest = t.substr(at+1);
            size_t co = rest.find(':');
            if (co != std::string::npos) { hold = atoi(rest.c_str()+co+1); rest = rest.substr(0,co); }
            joy_mask = (uint32_t)strtoul(t.substr(0,at).c_str(), nullptr, 0);
            joy_from = atol(rest.c_str()); joy_to = joy_from + hold;
        }
        else if (a == "--joy2") {
            std::string t = next("--joy2");
            size_t at = t.find('@'); if (at == std::string::npos) { fprintf(stderr,"error: --joy2 needs MASK@FRAME\n"); exit(1); }
            int hold = 4; std::string rest = t.substr(at+1);
            size_t co = rest.find(':');
            if (co != std::string::npos) { hold = atoi(rest.c_str()+co+1); rest = rest.substr(0,co); }
            joy2_mask = (uint32_t)strtoul(t.substr(0,at).c_str(), nullptr, 0);
            joy2_from = atol(rest.c_str()); joy2_to = joy2_from + hold;
        }
        else if (a == "--players")    players_mode = (uint8_t)atoi(next("--players"));
        else if (a == "--joy-map")    joy_override = (uint8_t)atoi(next("--joy-map"));
        else if (a == "--trace-q")    trace_q = true;
        else if (a == "--frame-log")  frame_log = true;
        else if (a == "--quiet")      quiet = true;
        else if (a == "--press") {
            std::string s = next("--press");
            size_t at = s.find('@');
            if (at == std::string::npos) { fprintf(stderr, "error: --press needs KEY@FRAME\n"); exit(1); }
            std::string k = s.substr(0, at);
            std::string rest = s.substr(at + 1);
            int hold = 4;
            size_t colon = rest.find(':');
            if (colon != std::string::npos) { hold = atoi(rest.c_str() + colon + 1); rest = rest.substr(0, colon); }
            uint8_t code;
            if (k.size() >= 2 && (k[0] == 'a' || k[0] == 'A') && k[1] >= '0' && k[1] <= '9')
                code = PS2_A[k[1] - '0'];
            else if (k.size() >= 2 && (k[0] == 'b' || k[0] == 'B') && k[1] >= '0' && k[1] <= '9')
                code = PS2_B[k[1] - '0'];
            else
                code = (uint8_t)strtol(k.c_str(), nullptr, 0);
            keys.push_back({ atol(rest.c_str()), hold, code, true });
        }
        else { fprintf(stderr, "error: unknown option %s (try --help)\n", argv[0]); usage(argv[0]); return 1; }
    }

    if (prefix.empty()) {
        const std::string& src = cart.empty() ? bios : cart;
        size_t slash = src.find_last_of('/');
        prefix = (slash == std::string::npos) ? src : src.substr(slash + 1);
        size_t dot = prefix.find_last_of('.');
        if (dot != std::string::npos) prefix = prefix.substr(0, dot);
        for (char& c : prefix) if (c == ' ' || c == '(' || c == ')' || c == '+') c = '_';
    }

    // Expand key events into press/release pairs sorted by frame.
    std::multimap<long, std::pair<uint8_t, bool>> key_sched;
    for (const KeyEvent& k : keys) {
        key_sched.insert({ k.frame, { k.code, true } });
        key_sched.insert({ k.frame + k.hold, { k.code, false } });
    }

    if (!shots.empty() || shot_every || shot_last) {
        std::string cmd = "mkdir -p '" + outdir + "'";
        if (system(cmd.c_str()) != 0) { fprintf(stderr, "error: cannot create %s\n", outdir.c_str()); return 2; }
    }

    FILE* df = stdout;
    if (!dumpfile.empty()) {
        df = fopen(dumpfile.c_str(), "w");
        if (!df) { fprintf(stderr, "error: cannot write %s\n", dumpfile.c_str()); return 2; }
    }

    Verilated::commandArgs(argc, argv);
    top = new Vtop();
    top->joy_override = joy_override;
    top->players = players_mode;

    IoctlDriver io;
    io.add(bios, 0);
    if (!cart.empty()) io.add(cart, 1);

    FrameGrabber fg;

    top->clk_48 = 0; top->clk_24 = 0;
    top->ioctl_download = 0; top->ioctl_upload = 0; top->ioctl_wr = 0;
    top->ioctl_addr = 0; top->ioctl_dout = 0; top->ioctl_din = 0; top->ioctl_index = 0;
    top->ps2_key = 0; top->inputs = 0;
    top->eval();

    long cycles = 0;
    int  clk24_div = 0;
    bool ps2_toggle = false;
    long last_reported = -1;

    while (fg.frame <= frames && cycles < max_cycles && !Verilated::gotFinish()) {

        // --- rising edge ---
        io.tick();
        top->joystick_0 = (fg.frame >= joy_from && fg.frame < joy_to) ? joy_mask : 0;
        top->joystick_1 = (fg.frame >= joy2_from && fg.frame < joy2_to) ? joy2_mask : 0;

        // Key events scheduled for this frame
        auto range = key_sched.equal_range(fg.frame);
        for (auto it = range.first; it != range.second; ) {
            ps2_toggle = !ps2_toggle;
            top->ps2_key = (uint16_t)((ps2_toggle ? (1 << 10) : 0) |
                                      (it->second.second ? (1 << 9) : 0) |
                                      it->second.first);
            if (!quiet)
                fprintf(stderr, "[key] frame %ld: %s scancode 0x%02X\n",
                        fg.frame, it->second.second ? "press" : "release", it->second.first);
            it = key_sched.erase(it);
            break;   // one event per clock so each toggle is seen
        }

        top->clk_48 = 1;
        if (++clk24_div >= 2) { clk24_div = 0; top->clk_24 = !top->clk_24; }
        top->eval();

        // CPU instruction trace. FETCH puts the PC on the bus; the opcode is
        // valid one state later, in EXECUTE (the dpram has 1 cycle latency).
        if (trace_cpu > 0 && fg.frame >= trace_from) {
            static uint16_t pending_pc = 0;
            static bool have_pc = false;
            if (CPU(state) == 1 /*FETCH*/) { pending_pc = CPU(ram_a); have_pc = true; }
            else if (CPU(state) == 2 /*EXECUTE*/ && have_pc) {
                have_pc = false;
                printf("%08llu  PC=%04X  op=%02X  P=%X X=%X D=%02X DF=%d  "
                       "R0=%04X R1=%04X R2=%04X R3=%04X R4=%04X R5=%04X R8=%04X RB=%04X  "
                       "IE=%d Q=%d EF=%X\n",
                       (unsigned long long)main_time, pending_pc, CPU(ram_q),
                       CPU(P), CPU(X), CPU(D), CPU(DF),
                       CPU(R)[0], CPU(R)[1], CPU(R)[2], CPU(R)[3],
                       CPU(R)[4], CPU(R)[5], CPU(R)[8], CPU(R)[0xB],
                       CPU(IE), CPU(Q), CPU(EF));
                if (--trace_cpu == 0) printf("[trace-cpu limit reached]\n");
            }
        }

        // Sample video on the rising edge (ce_pix is tied high in sim.v)
        bool boundary = fg.clock(top->VGA_VS, top->VGA_HS, top->VGA_DE,
                                 top->VGA_R != 0);

        {
            bool a_now = top->rootp->top__DOT__audio != 0;
            if (a_now != a_prev) { a_prev = a_now; a_edges++; }
            bool q_now = CPU(Q) != 0;
            if (q_now != q_prev) {
                if (q_prev) q_on_frames += (fg.frame - q_last_chg);
                q_last_chg = fg.frame;
                q_prev = q_now;
                q_edges++;
                if (trace_q) printf("Q %d frame %ld  (audio edges so far %ld)\n", q_now ? 1 : 0, (long)fg.frame, a_edges);
            }
        }

        if (boundary && fg.complete) {
            long f = fg.frame - 1;   // the frame that just finished

            bool do_shot = shots.count(f) || (shot_every && f % shot_every == 0) ||
                           (shot_last && f == frames - 1);
            bool do_dump = dumps.count(f) || (dump_every && f % dump_every == 0);

            if (frame_log)
                printf("frame %6ld  %3dx%-3d  hash %08X  %s\n",
                       f, fg.last_width, fg.last_height, fg.hash(),
                       fg.blank() ? "blank" : "");

            if (do_shot) {
                std::vector<uint8_t> rgb; int w, h;
                fg.to_rgb(rgb, w, h, scale);
                char name[512];
                snprintf(name, sizeof(name), "%s/%s_f%05ld.png", outdir.c_str(), prefix.c_str(), f);
                write_png(name, w, h, rgb);
                if (!quiet) fprintf(stderr, "[shot] %s (%dx%d source %dx%d)\n",
                                    name, w, h, fg.last_width, fg.last_height);
                if (want_ppm) {
                    snprintf(name, sizeof(name), "%s/%s_f%05ld.ppm", outdir.c_str(), prefix.c_str(), f);
                    write_ppm(name, w, h, rgb);
                }
                if (want_ascii) {
                    printf("--- frame %ld (%dx%d) ---\n", f, fg.last_width, fg.last_height);
                    fg.to_ascii(stdout);
                }
            }

            if (do_dump) dump_state(df, f, fg, want_vram);

            if (!quiet && !frame_log && f / 60 != last_reported) {
                last_reported = f / 60;
                fprintf(stderr, "[run] frame %ld/%ld  cycles %ld\n", f, frames, cycles);
            }
        }

        // --- falling edge ---
        top->clk_48 = 0;
        top->eval();

        main_time++;
        cycles++;
    }

    printf("\n");
    printf("done: %ld frames in %ld cycles\n", fg.frame, cycles);
    printf("      last frame %dx%d, hash %08X, %s\n",
           fg.last_width, fg.last_height, fg.hash(),
           fg.blank() ? "BLANK (nothing was drawn)" : "has content");
    if (cycles >= max_cycles) printf("      NOTE: stopped on --max-cycles\n");
    if (!fg.complete)         printf("      WARNING: no complete frame was ever captured\n");

    top->final();
    if (df != stdout) fclose(df);
    delete top;
    return 0;
}
