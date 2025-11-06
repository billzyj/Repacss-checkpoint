// Build:  gcc -O2 -fopenmp -o omp_dmtcp_demo omp_dmtcp_demo.c
// Run:    ./omp_dmtcp_demo -s 120 -w 50 -F state.txt
// Purpose: Verify DMTCP can checkpoint/restart a multithreaded (OpenMP) program.

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <omp.h>

static void busy_work_ms(int ms) {
  // Simple CPU work ~ms (not precise). Keeps threads busy between prints.
  const uint64_t target = (uint64_t)ms * 1000ULL;
  struct timespec start, now;
  clock_gettime(CLOCK_MONOTONIC, &start);
  for (;;) {
    // some arithmetic to defeat optimization
    double x = 1.0;
    for (int i = 0; i < 1000; ++i) x = x * 1.0000001 + 0.0000001;
    (void)x;
    clock_gettime(CLOCK_MONOTONIC, &now);
    uint64_t us = (now.tv_sec - start.tv_sec) * 1000000ULL
                + (now.tv_nsec - start.tv_nsec) / 1000ULL;
    if (us >= target) break;
  }
}

static void usage(const char* prog) {
  fprintf(stderr,
    "Usage: %s [-s STEPS] [-w WORK_MS] [-F STATE_FILE]\n"
    "  -s STEPS     total steps to run (default 60)\n"
    "  -w WORK_MS   busy-work per step per thread in ms (default 25)\n"
    "  -F FILE      optional state file to record progress (thread 0 only)\n",
    prog);
}

int main(int argc, char** argv) {
  int steps = 60;
  int work_ms = 25;
  const char* state_file = NULL;

  int opt;
  while ((opt = getopt(argc, argv, "s:w:F:h")) != -1) {
    switch (opt) {
      case 's': steps = atoi(optarg); break;
      case 'w': work_ms = atoi(optarg); break;
      case 'F': state_file = optarg; break;
      case 'h': default: usage(argv[0]); return (opt=='h'?0:1);
    }
  }

  // Make stdout unbuffered so logs flush immediately (useful under DMTCP).
  setvbuf(stdout, NULL, _IONBF, 0);

  const int max_threads = omp_get_max_threads();
  const char* omp_env = getenv("OMP_NUM_THREADS");
  printf("[omp_dmtcp_demo] PID=%ld | max_threads=%d | OMP_NUM_THREADS=%s\n",
         (long)getpid(), max_threads, omp_env ? omp_env : "(unset)");

  // A counter that should continue monotonically after restart.
  // Declared static so you can spot continuity easily in logs.
  static int global_counter = 0;

  for (int step = 0; step < steps; ++step, ++global_counter) {
    #pragma omp parallel
    {
      int tid = omp_get_thread_num();
      int nth = omp_get_num_threads();

      // Each thread does a smidge of work
      busy_work_ms(work_ms);

      // One print per thread per step (kept short)
      printf("STEP=%d THREAD=%d/%d PID=%ld\n",
             step, tid, nth, (long)getpid());

      #pragma omp barrier
      #pragma omp single
      {
        // Thread 0 records consolidated step info; this helps verify continuity
        if (state_file) {
          FILE* f = fopen(state_file, (step==0) ? "w" : "a");
          if (f) {
            time_t now = time(NULL);
            char ts[64];
            struct tm tm; localtime_r(&now, &tm);
            strftime(ts, sizeof(ts), "%F %T", &tm);
            fprintf(f, "%s STEP=%d global_counter=%d threads=%d\n",
                    ts, step, global_counter, nth);
            fclose(f);
          }
        }
        // Slow down one place per step so you have time to checkpoint
        // (sleep, not busy CPU)
        usleep(2000 * 1000); // 2000 ms
      }
    } // end parallel
  }

  printf("[omp_dmtcp_demo] DONE: steps=%d final_global_counter=%d\n",
         steps, global_counter);
  return 0;
}
