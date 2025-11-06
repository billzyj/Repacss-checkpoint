#include <mpi.h>
#include <stdio.h>
#include <unistd.h>
#include <stdlib.h>

int main(int argc, char *argv[]) {
    MPI_Init(&argc, &argv);
    int rank, size;
    MPI_Comm_rank(MPI_COMM_WORLD, &rank);
    MPI_Comm_size(MPI_COMM_WORLD, &size);

    static int counter = 0;  // persists across DMTCP restart
    char hostname[256]; gethostname(hostname, sizeof(hostname));

    if (rank == 0) {
        printf("[start] world=%d host[0]=%s\n", size, hostname);
        fflush(stdout);
    }

    // Config via env
    int max_steps = 120;
    const char *env = getenv("MAX_STEPS");
    if (env) { max_steps = atoi(env); if (max_steps < 1) max_steps = 1; }
    int sleep_ms = 1000;
    const char *env2 = getenv("SLEEP_MS");
    if (env2) { sleep_ms = atoi(env2); if (sleep_ms < 0) sleep_ms = 0; }

    // Per-rank buffer used in gather
    int my_value = 0;
    int *gather_buf = NULL;
    if (rank == 0) gather_buf = (int*)malloc(sizeof(int) * size);

    for (; counter < max_steps; counter++) {
        // 1) Root announces current step to everyone
        int step = counter;
        MPI_Bcast(&step, 1, MPI_INT, 0, MPI_COMM_WORLD);

        // 2) Everyone (including rank 0) computes a tiny value
        //    to "report back" to rank 0
        my_value = rank * (step + 1);

        // 3) Gather all values at root
        MPI_Gather(&my_value, 1, MPI_INT,
                   gather_buf, 1, MPI_INT,
                   0, MPI_COMM_WORLD);

        // 4) Root prints a short summary
        if (rank == 0) {
            printf("[step %d] gathered:", step);
            // print up to first 8 values to keep logs concise
            int limit = (size < 8) ? size : 8;
            for (int i = 0; i < limit; i++) printf(" %d", gather_buf[i]);
            if (size > limit) printf(" ...(+%d more)", size - limit);
            printf("\n");
            fflush(stdout);
        }

        // 5) Small delay so you can see progress & checkpoint cleanly
        if (sleep_ms > 0) usleep((useconds_t)sleep_ms * 1000);
    }

    if (rank == 0) {
        printf("[finish] completed steps=%d\n", counter);
        fflush(stdout);
    }
    if (gather_buf) free(gather_buf);

    MPI_Finalize();
    return 0;
}
