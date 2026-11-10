// Savestate simulation driver: models the HPS side of the save file and checks that
// the program goes on the same way after a load as it did after the save.
#include "Vtb.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <vector>
#include <cstring>
#include <cstdlib>

static Vtb *t;
static uint64_t cyc = 0;
static std::vector<uint16_t> file;          // save file, 16-bit words
static std::vector<uint32_t> trace;
static int info_last = -1;

static void tick() {
	t->clk = 0; t->eval();
	t->clk = 1; t->eval();
	cyc++;
	if (t->trace_we) trace.push_back(t->trace_d);
	if (t->info_req) { info_last = t->info; printf("  info %d at %llu\n", t->info, (unsigned long long)cyc); }
}

// one SD request, the way hps_io/Main do it: lba must not be past the end of the file
static void sd_service() {
	if (!t->sd_rd && !t->sd_wr) return;
	bool wr = t->sd_wr;
	uint32_t lba = t->sd_lba;
	uint32_t blks = t->sd_blk_cnt + 1;
	for (int i = 0; i < 20; i++) tick();
	t->sd_ack = 1;
	t->sd_buff_addr = 0;
	tick(); tick();
	if (wr) {
		uint32_t size = file.size() / 256;
		if (lba > size) printf("  SD write past the end: lba %u size %u\n", lba, size);
		for (uint32_t a = 0; a < blks * 256; a++) {
			t->sd_buff_addr = a;
			for (int i = 0; i < 4; i++) tick();
			uint32_t w = lba * 256 + a;
			if (lba <= size) {
				if (w >= file.size()) file.resize(w + 1, 0xFFFF);
				file[w] = t->sd_buff_din;
			}
		}
	} else {
		for (uint32_t a = 0; a < blks * 256; a++) {
			uint32_t w = lba * 256 + a;
			t->sd_buff_addr = a;
			t->sd_buff_dout = (w < file.size()) ? file[w] : 0xFFFF;
			tick();
			t->sd_buff_wr = 1; tick();
			t->sd_buff_wr = 0; tick(); tick();
		}
	}
	t->sd_ack = 0;
	tick();
}

static void run(uint64_t n) {
	for (uint64_t i = 0; i < n; i++) { tick(); sd_service(); }
}

static int dbg = 1;
static void request(bool load, int slot) {
	t->slot = slot;
	if (load) t->load = 1; else t->save = 1;
	tick(); tick();
	t->load = 0; t->save = 0;
	if (dbg) { dbg = 0; int n = 0; int oas = 1; while (t->busy) { tick(); sd_service(); if (!t->dbg_as && oas && n < 120 && ((t->dbg_fc >> 1) == 7 || t->dbg_addr >= 0x7F0000 || t->dbg_addr < 0x40)) { n++; printf("  bus %06x fc%x d %04x at %llu\n", t->dbg_addr*2, t->dbg_fc, t->dbg_din, (unsigned long long)cyc); } oas = t->dbg_as; } }
	while (!t->busy) tick();
	while (t->busy) { tick(); sd_service(); }
}

int main(int argc, char **argv) {
	setvbuf(stdout, NULL, _IONBF, 0);
	Verilated::commandArgs(argc, argv);
	t = new Vtb;
	file.assign(0x12000 / 2, 0x1111);   // backup RAM + memory card already there

	t->reset = 1;
	for (int i = 0; i < 2000; i++) tick();
	t->reset = 0;
	run(400000);
	printf("trace after start: %zu\n", trace.size());
	t->img_size = file.size() * 2;
	t->img_mounted = 1; tick(); t->img_mounted = 0;

	int fails = 0;
	// a few rounds at different points
	for (int round = 0; round < 6; round++) {
		run(1500000 + round * 777777);
		printf("round %d: save at cycle %llu, irqs %u, trace %zu\n", round, (unsigned long long)cyc, t->irq_count, trace.size());
		request(false, 1);
		if (getenv("QUICK")) { printf("quick exit, info %d\n", info_last); return 0; }
		size_t t0 = trace.size();
		uint32_t irq0 = t->irq_count;
		run(1200000);
		std::vector<uint32_t> after_save(trace.begin() + t0, trace.end());
		uint32_t irqs_save = t->irq_count - irq0;

		run(900000 + round * 333333);   // the program goes on somewhere else
		request(true, 1);
		if (info_last != 19) { printf("  load failed: info %d\n", info_last); fails++; continue; }
		size_t t1 = trace.size();
		irq0 = t->irq_count;
		run(1200000);
		std::vector<uint32_t> after_load(trace.begin() + t1, trace.end());
		uint32_t irqs_load = t->irq_count - irq0;

		size_t n = std::min(after_save.size(), after_load.size());
		size_t bad = n;
		for (size_t i = 0; i < n; i++) if (after_save[i] != after_load[i]) { bad = i; break; }
		printf("  after save %zu words, after load %zu words, irqs %u/%u, %s", after_save.size(), after_load.size(),
		       irqs_save, irqs_load, bad == n ? "match\n" : "MISMATCH");
		if (bad != n) {
			printf(" at %zu: %08x vs %08x\n", bad, after_save[bad], after_load[bad]);
			fails++;
		}
		if (n < 1000) { printf("  too little trace\n"); fails++; }
	}

	// an empty slot must not change anything
	size_t te = trace.size();
	request(true, 3);
	printf("empty slot: info %d (expect 20)\n", info_last);
	if (info_last != 20) fails++;
	run(200000);
	if (trace.size() <= te) { printf("program stopped\n"); fails++; }

	printf("file size %zu bytes (expect 0x120000 = %d)\n", file.size() * 2, 0x120000);
	if (file.size() * 2 != 0x120000) fails++;
	// the backup area must be untouched
	for (size_t i = 0; i < 0x12000 / 2; i++) if (file[i] != 0x1111) { printf("backup area changed at %zu\n", i); fails++; break; }

	printf(fails ? "FAILED (%d)\n" : "PASSED\n", fails);
	delete t;
	return fails ? 1 : 0;
}
