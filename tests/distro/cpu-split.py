import os
from pathlib import Path
import sys


def cpu_list(text):
    cpus = set()
    for part in text.strip().split(','):
        ends = part.split('-')
        cpus.update(range(int(ends[0]), int(ends[-1]) + 1))
    return cpus


try:
    jobs = int(sys.argv[1])
    root = Path('/sys/devices/system/cpu')
    available = os.sched_getaffinity(0) & cpu_list((root / 'online').read_text())
    seen, cores = set(), []
    for cpu in sorted(available):
        if cpu in seen:
            continue
        siblings = cpu_list((root / f'cpu{cpu}/topology/thread_siblings_list').read_text())
        if not siblings <= available:
            continue
        if not siblings or cpu not in siblings or siblings & seen:
            raise ValueError('Invalid sibling topology')
        frequency = int((root / f'cpu{cpu}/cpufreq/cpuinfo_max_freq').read_text())
        if frequency <= 0:
            raise ValueError('Missing maximum frequency')
        cores.append((frequency, sorted(siblings)))
        seen.update(siblings)
    if jobs < 1 or len(cores) < jobs:
        raise ValueError('Not enough whole cores')
    shares = [[] for _ in range(jobs)]
    for index, (_, siblings) in enumerate(sorted(cores, key=lambda core: (-core[0], core[1]))):
        shares[index % jobs].extend(siblings)
    for share in shares:
        print(','.join(map(str, sorted(share))))
except (OSError, ValueError, IndexError):
    sys.exit(1)
