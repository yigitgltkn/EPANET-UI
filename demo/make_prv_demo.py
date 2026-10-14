"""Writes a small synthetic two-zone network with one PRV (public, made up).

A reservoir on a hill feeds a high zone; a single PRV feeds a low zone.
Demands follow a 24 h diurnal pattern so the pressure upstream of the PRV
changes through the day while the PRV holds its downstream setting.
"""
import math
import sys


def terrain(x, y):
    return 118.0 - 0.042 * x + 5.0 * math.sin(y / 260.0) + 3.0 * math.cos(x / 210.0 + y / 400.0)


def main(out_path):
    rows = [150, 400, 650, 900]
    high_cols = [250, 400, 550, 700]
    low_cols = [1000, 1150, 1300, 1450, 1600]

    junctions = []   # (id, x, y, elev, base demand)
    pipes = []       # (id, n1, n2, length, diameter, roughness)

    def add_grid(prefix, cols, diam_main, diam_side, demand):
        for c, x in enumerate(cols, start=1):
            for r, y in enumerate(rows, start=1):
                junctions.append((f"{prefix}{c}{r}", x, y, terrain(x, y), demand))
        for c, x in enumerate(cols, start=1):
            for r, y in enumerate(rows, start=1):
                if c < len(cols):
                    d = diam_main if r in (2, 3) else diam_side
                    pipes.append((f"{prefix}{c}{r}-{prefix}{c + 1}{r}", f"{prefix}{c}{r}",
                                  f"{prefix}{c + 1}{r}", cols[c] - x, d, 120))
                if r < len(rows):
                    pipes.append((f"{prefix}{c}{r}-{prefix}{c}{r + 1}", f"{prefix}{c}{r}",
                                  f"{prefix}{c}{r + 1}", rows[r] - y, diam_side, 120))

    add_grid("H", high_cols, 200, 150, 0.9)
    add_grid("L", low_cols, 150, 100, 0.9)

    # Connections: reservoir main, PRV station
    junctions.append(("HIN", 100, 525, terrain(100, 525), 0.0))
    # Both sides of the PRV are in one chamber, so at one elevation
    junctions.append(("PU", 800, 525, terrain(840, 525), 0.0))
    junctions.append(("PD", 880, 525, terrain(840, 525), 0.0))
    pipes.append(("MAIN", "R1", "HIN", 900, 200, 110))
    pipes.append(("HIN-H12", "HIN", "H12", 195, 200, 120))
    pipes.append(("HIN-H13", "HIN", "H13", 195, 200, 120))
    pipes.append(("H42-PU", "H42", "PU", 160, 200, 120))
    pipes.append(("H43-PU", "H43", "PU", 160, 200, 120))
    pipes.append(("PD-L12", "PD", "L12", 173, 200, 120))
    pipes.append(("PD-L13", "PD", "L13", 173, 200, 120))

    # Diurnal demand pattern, 48 half-hour multipliers with a mean of 1
    mult = []
    for i in range(48):
        h = i * 0.5
        m = (0.45 + 0.90 * math.exp(-((h - 7.5) / 2.2) ** 2)
             + 0.75 * math.exp(-((h - 19.0) / 2.6) ** 2)
             + 0.25 * math.exp(-((h - 13.0) / 3.0) ** 2))
        mult.append(m)
    mean = sum(mult) / len(mult)
    mult = [m / mean for m in mult]

    L = []
    L += ["[TITLE]", "PRV demo network (synthetic)",
          "Reservoir - high zone - PRV - low zone, 24 h diurnal demand", ""]
    L += ["[JUNCTIONS]", ";ID              Elev        Demand      Pattern"]
    for jid, x, y, z, q in junctions:
        L.append(f" {jid:<16}{z:<12.2f}{q:<12.3f}DIURNAL")
    L += ["", "[RESERVOIRS]", ";ID              Head        Pattern", " R1              150", ""]
    L += ["[TANKS]", ""]
    L += ["[PIPES]", ";ID              Node1           Node2           Length      Diameter    Roughness   MinorLoss   Status"]
    for pid, n1, n2, length, diam, rough in pipes:
        L.append(f" {pid:<16}{n1:<16}{n2:<16}{length:<12.1f}{diam:<12}{rough:<12}0           Open")
    L += ["", "[PUMPS]", ""]
    L += ["[VALVES]", ";ID              Node1           Node2           Diameter    Type    Setting     MinorLoss",
          " PRV1            PU              PD              150         PRV     30          0", ""]
    L += ["[PATTERNS]", ";ID              Multipliers"]
    for i in range(0, 48, 6):
        L.append(" DIURNAL         " + "  ".join(f"{m:.3f}" for m in mult[i:i + 6]))
    L += ["", "[TIMES]",
          " Duration           24:00", " Hydraulic Timestep 0:30", " Quality Timestep   0:05",
          " Pattern Timestep   0:30", " Pattern Start      0:00", " Report Timestep    0:30",
          " Report Start       0:00", " Start ClockTime    12 am", " Statistic          NONE", ""]
    L += ["[OPTIONS]",
          " Units              LPS", " Headloss           H-W", " Specific Gravity   1.0",
          " Viscosity          1.0", " Trials             40", " Accuracy           0.001",
          " Unbalanced         Continue 10", " Pattern            DIURNAL",
          " Demand Multiplier  1.0", " Quality            None", ""]
    L += ["[COORDINATES]", ";Node            X-Coord         Y-Coord"]
    for jid, x, y, z, q in junctions:
        L.append(f" {jid:<16}{x:<16.2f}{y:<16.2f}")
    L.append(f" {'R1':<16}{-300.0:<16.2f}{525.0:<16.2f}")
    L += ["", "[END]", ""]

    with open(out_path, "w", encoding="ascii", newline="\r\n") as f:
        f.write("\n".join(L))
    print(f"{len(junctions)} junctions, {len(pipes)} pipes, 1 PRV -> {out_path}")
    print("pattern min/max: %.2f / %.2f" % (min(mult), max(mult)))


if __name__ == "__main__":
    main(sys.argv[1])
