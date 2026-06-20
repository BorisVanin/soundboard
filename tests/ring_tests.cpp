//
//  ring_tests.cpp — standalone unit tests for the driver's shared-memory ring +
//  protocol (RingOwner / RingClient). No coreaudiod, no HAL, no install required.
//
//  Build & run:  tests/run.sh        (also emits an llvm-cov coverage report)
//  or:           c++ -std=c++17 -I ../LoopbackDriver/src ring_tests.cpp \
//                    ../LoopbackDriver/src/RingOwner.cpp \
//                    ../LoopbackDriver/src/RingClient.cpp -o /tmp/ring_tests && /tmp/ring_tests
//
#include "RingOwner.h"
#include "RingClient.h"
#include <cstdio>
#include <cstdint>
#include <cmath>
#include <cstring>
#include <vector>

static int g_pass = 0, g_fail = 0;
static const char* g_test = "";
#define CHECK(c) do { if (c) ++g_pass; else { ++g_fail; \
    std::printf("  FAIL [%s] %s:%d  %s\n", g_test, __FILE__, __LINE__, #c); } } while (0)
#define CHECK_NEAR(a,b,eps) do { double _d=(double)(a)-(double)(b); if (_d<0)_d=-_d; \
    if (_d<=(eps)) ++g_pass; else { ++g_fail; \
    std::printf("  FAIL [%s] %s:%d  %s≈%s  (%.6f vs %.6f)\n", g_test, __FILE__, __LINE__, #a,#b,(double)(a),(double)(b)); } } while (0)

static const RingOutFormat F32{2, 32, true};
static const RingOutFormat I16{2, 16, false};
static const RingOutFormat I24{2, 24, false};
static const RingOutFormat I32{2, 32, false};
static const RingOutFormat MONO16{1, 16, false};

// Fill a stereo float buffer with distinguishable ramps.
static std::vector<float> ramp(uint32_t frames, float l0, float r0, float step) {
    std::vector<float> v(frames * 2);
    for (uint32_t f = 0; f < frames; ++f) { v[f*2] = l0 + step*f; v[f*2+1] = r0 - step*f; }
    return v;
}
static int32_t read24(const unsigned char* b) {
    int32_t s = b[0] | (b[1] << 8) | (b[2] << 16);
    if (s & 0x800000) s |= ~0xFFFFFF;
    return s;
}

// ─────────────────────────────────────────────────────────────────────────────
static void test_owner_create_destroy() {
    g_test = "owner_create_destroy";
    RingOwner o;
    CHECK(!o.isCreated());
    CHECK(o.create("/sbt.cd"));
    CHECK(o.isCreated());
    CHECK(o.lastErrno() == 0);
    CHECK(o.create("/sbt.cd"));                 // idempotent: already created
    SoundboardRingHeader* h = o.header();
    CHECK(h != nullptr);
    CHECK(h->magic == kSoundboardRingMagic);
    CHECK(h->version == kSoundboardRingVersion);
    CHECK(h->channels == kSoundboardRingChannels);
    CHECK(h->frameCapacity == kSoundboardRingFrameCapacity);
    CHECK(h->dataOffset == sizeof(SoundboardRingHeader));
    CHECK(h->driverState == kSoundboardRingAlive);
    o.destroy();
    CHECK(!o.isCreated());
    o.destroy();                                // idempotent
}

static void test_owner_create_failure() {
    g_test = "owner_create_failure";
    RingOwner o;
    // POSIX shm names are limited (~31 chars on macOS); an over-long name fails.
    char longname[80]; std::memset(longname, 'x', sizeof(longname)); longname[0]='/'; longname[79]=0;
    CHECK(!o.create(longname));
    CHECK(o.lastErrno() != 0);
    CHECK(!o.isCreated());
}

static void test_info() {
    g_test = "info";
    RingOwner o; o.create("/sbt.info");
    SoundboardRingInfo i = o.info();
    CHECK(i.protocolVersion == kSoundboardRingVersion);
    CHECK(i.driverState == kSoundboardRingAlive);
    CHECK(i.frameCapacity == kSoundboardRingFrameCapacity);
    CHECK(i.channels == kSoundboardRingChannels);
    CHECK(i.sampleRate == kSoundboardRingSampleRate);
    CHECK(std::strcmp(i.name, "/sbt.info") == 0);
    o.destroy();
}

static void test_session() {
    g_test = "session";
    RingOwner o; o.create("/sbt.sess");
    CHECK(o.grantedSession() == 0);
    o.setSession(0x1234);
    CHECK(o.grantedSession() == 0x1234);
    o.setSession(0);
    CHECK(o.grantedSession() == 0);
    o.destroy();
}

static void test_client_attach() {
    g_test = "client_attach";
    RingClient c;
    CHECK(!c.attach("/sbt.nope.nonexistent"));      // not created → fail
    CHECK(c.lastErrno() != 0);
    CHECK(!c.valid());

    RingOwner o; o.create("/sbt.att");
    CHECK(c.attach("/sbt.att"));
    CHECK(c.valid());
    CHECK(c.attach("/sbt.att"));                     // idempotent
    SoundboardRingInfo i = c.readHeader();
    CHECK(i.channels == kSoundboardRingChannels);
    CHECK(i.frameCapacity == kSoundboardRingFrameCapacity);
    c.detach();
    CHECK(!c.valid());
    c.detach();                                      // idempotent
    o.destroy();
}

static void test_client_attach_bad_magic() {
    g_test = "client_attach_bad_magic";
    RingOwner o; o.create("/sbt.badmagic");
    o.header()->magic = 0xDEADBEEF;                  // corrupt what the owner advertised
    RingClient c;
    CHECK(!c.attach("/sbt.badmagic"));               // validation rejects it
    CHECK(c.lastErrno() == EINVAL);
    o.destroy();
}

static void test_client_claim_beat_release() {
    g_test = "client_claim_beat_release";
    RingOwner o; o.create("/sbt.claim");
    RingClient c; c.attach("/sbt.claim");
    c.claim(0xAA);
    CHECK(o.header()->appSession == 0xAA);
    uint64_t b0 = o.header()->heartbeat;
    c.beat(); c.beat();
    CHECK(o.header()->heartbeat == b0 + 2);
    c.release();
    CHECK(o.header()->appSession == 0);
    c.detach(); o.destroy();
}

static void test_consume_gating() {
    g_test = "consume_gating";
    RingOwner o; o.create("/sbt.gate");
    RingClient c; c.attach("/sbt.gate");
    float dst[8 * 2];

    // No grant → silence, 0 sourced.
    CHECK(o.consume(dst, 8, F32) == 0);

    // Grant but session mismatch in the header → silence.
    o.setSession(0x55); c.claim(0x66); c.beat();
    CHECK(o.consume(dst, 8, F32) == 0);

    // Matching session + CLOSING state → silence.
    c.claim(0x55);
    o.header()->driverState = kSoundboardRingClosing;
    CHECK(o.consume(dst, 8, F32) == 0);
    o.header()->driverState = kSoundboardRingAlive;

    c.detach(); o.destroy();
}

static void test_consume_liveness() {
    g_test = "consume_liveness";
    RingOwner o; o.create("/sbt.live");
    o.setHeartbeatStallLimit(2);
    RingClient c; c.attach("/sbt.live");
    c.claim(0x9); c.beat(); o.setSession(0x9);

    auto buf = ramp(64, 0.1f, -0.1f, 0.0f);
    c.produce(buf.data(), 64);
    float dst[8 * 2];
    // First consume observes the grant and opens the liveness window; then with no
    // new beat the stall accrues and after the limit it silences despite data.
    CHECK(o.consume(dst, 8, F32) > 0);   // #1 opens window
    CHECK(o.consume(dst, 8, F32) > 0);   // #2 stall 1
    CHECK(o.consume(dst, 8, F32) > 0);   // #3 stall 2
    CHECK(o.consume(dst, 8, F32) == 0);  // #4 stall 3 > limit → dead → silence
    // A fresh beat revives it.
    c.beat();
    CHECK(o.consume(dst, 8, F32) > 0);
    c.detach(); o.destroy();
}

static void test_roundtrip_and_formats() {
    g_test = "roundtrip_and_formats";
    RingOwner o; o.create("/sbt.rt");
    RingClient c; c.attach("/sbt.rt");
    c.claim(0x7); c.beat(); o.setSession(0x7);

    // float32 round-trip: exact values survive.
    {
        auto in = ramp(4, 0.10f, -0.10f, 0.05f);
        CHECK(c.produce(in.data(), 4) == 4);
        c.beat();
        float out[4 * 2];
        CHECK(o.consume(out, 4, F32) == 4);
        for (uint32_t i = 0; i < 8; ++i) CHECK_NEAR(out[i], in[i], 1e-6);
    }
    // int16 conversion.
    {
        float in[2] = {0.5f, -0.5f};               // one stereo frame
        CHECK(c.produce(in, 1) == 1);
        c.beat();
        int16_t out[2];
        CHECK(o.consume(out, 1, I16) == 1);
        CHECK_NEAR(out[0], 16383, 2);
        CHECK_NEAR(out[1], -16383, 2);
    }
    // int24 conversion.
    {
        float in[2] = {0.25f, -0.25f};
        c.produce(in, 1); c.beat();
        unsigned char out[2 * 3];
        CHECK(o.consume(out, 1, I24) == 1);
        CHECK_NEAR(read24(out + 0), (int32_t)(0.25f * 8388607.0f), 4);
        CHECK_NEAR(read24(out + 3), (int32_t)(-0.25f * 8388607.0f), 4);
    }
    // int32 conversion.
    {
        float in[2] = {1.0f, -1.0f};
        c.produce(in, 1); c.beat();
        int32_t out[2];
        CHECK(o.consume(out, 1, I32) == 1);
        CHECK(out[0] > 2000000000);
        CHECK(out[1] < -2000000000);
    }
    // mono downmix: (L+R)/2.
    {
        float in[2] = {0.4f, 0.6f};
        c.produce(in, 1); c.beat();
        int16_t out[1];
        CHECK(o.consume(out, 1, MONO16) == 1);
        CHECK_NEAR(out[0], (int16_t)(0.5f * 32767.0f), 2);
    }
    c.detach(); o.destroy();
}

static void test_underrun() {
    g_test = "underrun";
    RingOwner o; o.create("/sbt.under");
    RingClient c; c.attach("/sbt.under");
    c.claim(0x3); c.beat(); o.setSession(0x3);

    auto in = ramp(3, 0.2f, -0.2f, 0.1f);
    c.produce(in.data(), 3);
    c.beat();
    float out[8 * 2];
    for (uint32_t i = 0; i < 16; ++i) out[i] = 123.0f;
    CHECK(o.consume(out, 8, F32) == 3);              // only 3 available
    // frames 0..2 carry data, 3..7 are silence.
    CHECK_NEAR(out[0], in[0], 1e-6);
    CHECK_NEAR(out[6], 0.0f, 1e-6);                  // frame 3 L
    CHECK_NEAR(out[15], 0.0f, 1e-6);                 // frame 7 R
    c.detach(); o.destroy();
}

static void test_lapped_and_corrupt() {
    g_test = "lapped_and_corrupt";
    RingOwner o; o.create("/sbt.lap");
    RingClient c; c.attach("/sbt.lap");
    c.claim(0x4); c.beat(); o.setSession(0x4);
    float dst[8 * 2];

    // Producer lapped the consumer: writeIndex far ahead of readIndex (> capacity).
    o.header()->readIndex = 0;
    o.header()->writeIndex = kSoundboardRingFrameCapacity + 1000;
    uint32_t got = o.consume(dst, 8, F32);
    CHECK(got == 8);                                 // bounded; skips stale, no crash
    // readIndex was snapped to (writeIndex - capacity) = 1000, then advanced by give=8.
    CHECK(o.header()->readIndex == 1000 + 8);

    // Corrupt indices: readIndex > writeIndex. Must not crash; stays bounded.
    o.header()->readIndex = 5000;
    o.header()->writeIndex = 10;
    got = o.consume(dst, 8, F32);
    CHECK(got <= 8);
    c.detach(); o.destroy();
}

static void test_produce_drop_on_full() {
    g_test = "produce_drop_on_full";
    RingOwner o; o.create("/sbt.full");
    RingClient c; c.attach("/sbt.full");
    // No consumer draining: fill the whole ring, then the next write drops.
    std::vector<float> in(kSoundboardRingFrameCapacity * 2, 0.5f);
    uint32_t wrote = c.produce(in.data(), kSoundboardRingFrameCapacity);
    CHECK(wrote == kSoundboardRingFrameCapacity);    // exactly fills it
    float more[2] = {0.1f, 0.1f};
    CHECK(c.produce(more, 1) == 0);                  // full → drop, reader's data protected
    c.detach(); o.destroy();
}

static void test_consume_not_created() {
    g_test = "consume_not_created";
    RingOwner o;                                     // never created
    float dst[4 * 2];
    CHECK(o.consume(dst, 4, F32) == 0);              // header null → 0 sourced
    CHECK(o.info().driverState == kSoundboardRingClosing);  // info() with no header
    o.setSession(5);                                 // setSession with no header (no heartbeat read)
    CHECK(o.grantedSession() == 5);
}

static void test_consume_multichannel_and_oddfmt() {
    g_test = "consume_multichannel_and_oddfmt";
    RingOwner o; o.create("/sbt.mc");
    RingClient c; c.attach("/sbt.mc");
    c.claim(0x2); c.beat(); o.setSession(0x2);
    float in[2] = {0.3f, -0.3f};
    c.produce(in, 1); c.beat();
    // 3-channel float out: ch0=L, ch1=R, ch2=silence (covers the c>=2 path).
    RingOutFormat F3{3, 32, true};
    float out3[3]; out3[2] = 9.0f;
    CHECK(o.consume(out3, 1, F3) == 1);
    CHECK_NEAR(out3[0], 0.3f, 1e-6);
    CHECK_NEAR(out3[1], -0.3f, 1e-6);
    CHECK_NEAR(out3[2], 0.0f, 1e-6);
    // Unsupported bit depth: writeFrame matches no branch and leaves dst untouched.
    c.produce(in, 1); c.beat();
    RingOutFormat ODD{2, 8, false};
    unsigned char out8[2] = {0x7E, 0x7E};
    o.consume(out8, 1, ODD);                         // must not crash
    CHECK(out8[0] == 0x7E);
    c.detach(); o.destroy();
}

static void test_client_unattached() {
    g_test = "client_unattached";
    RingClient c;                                    // never attached
    float in[2] = {1.0f, 1.0f};
    CHECK(c.produce(in, 1) == 0);                    // null guard
    c.claim(1); c.release(); c.beat();               // all no-ops, no crash
    CHECK(c.readHeader().channels == 0);             // null guard
}

static void test_attach_validation_variants() {
    g_test = "attach_validation_variants";
    { RingOwner o; o.create("/sbt.v1"); o.header()->version = 99;
      RingClient c; CHECK(!c.attach("/sbt.v1")); CHECK(c.lastErrno() == EINVAL); o.destroy(); }
    { RingOwner o; o.create("/sbt.v2"); o.header()->channels = 5;
      RingClient c; CHECK(!c.attach("/sbt.v2")); o.destroy(); }
    { RingOwner o; o.create("/sbt.v3"); o.header()->frameCapacity = 0;
      RingClient c; CHECK(!c.attach("/sbt.v3")); o.destroy(); }
    { RingOwner o; o.create("/sbt.v4"); o.header()->frameCapacity = 3;   // not power of two
      RingClient c; CHECK(!c.attach("/sbt.v4")); o.destroy(); }
}

int main() {
    test_owner_create_destroy();
    test_owner_create_failure();
    test_info();
    test_session();
    test_client_attach();
    test_client_attach_bad_magic();
    test_client_claim_beat_release();
    test_consume_gating();
    test_consume_liveness();
    test_roundtrip_and_formats();
    test_underrun();
    test_lapped_and_corrupt();
    test_produce_drop_on_full();
    test_consume_not_created();
    test_consume_multichannel_and_oddfmt();
    test_client_unattached();
    test_attach_validation_variants();

    std::printf("\n%s: %d passed, %d failed\n", g_fail ? "FAILURE" : "SUCCESS", g_pass, g_fail);
    return g_fail ? 1 : 0;
}
