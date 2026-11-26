# Profiling layer for the SwiftCrossUI fork work: perf (works against
# Colima's kernel with --privileged) and valgrind/callgrind.
FROM playhouse-linux-ui
RUN apt-get update && apt-get install -y --no-install-recommends linux-perf valgrind \
    && rm -rf /var/lib/apt/lists/*
