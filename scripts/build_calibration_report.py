import argparse
import csv
import json
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
from PIL import Image


def read_csv(path):
    with Path(path).open(newline="", encoding="utf-8-sig") as handle:
        return list(csv.DictReader(handle))


def as_float(row, key):
    value = row.get(key, "")
    if value == "":
        return None
    return float(value)


def normalize(values):
    clean = [value for value in values if value is not None]
    if not clean:
        return values
    lo = min(clean)
    hi = max(clean)
    span = hi - lo
    if span <= 1.0e-9:
        return [0.0 if value is not None else None for value in values]
    return [(value - lo) / span if value is not None else None for value in values]


def plot_series(ax, time, measured, simulated, title, measured_label, simulated_label):
    measured_norm = normalize(measured)
    simulated_norm = normalize(simulated)
    ax.plot(time, measured_norm, color="#f7a431", linewidth=1.8, label=measured_label)
    ax.plot(time, simulated_norm, color="#63d5ff", linewidth=1.5, label=simulated_label)
    ax.set_title(title)
    ax.set_xlabel("measured time (s)")
    ax.set_ylabel("normalized shape")
    ax.grid(True, alpha=0.4)
    ax.legend(loc="upper right", frameon=False, fontsize=8)


def make_static_plot(output_dir, rows, report):
    time = [as_float(row, "measuredTimeSeconds") for row in rows]
    series = [
        (
            "HRR shape",
            [as_float(row, "measuredHrrKW") for row in rows],
            [as_float(row, "simHrrProxy") for row in rows],
            "NIST HRR",
            "CUDA HRR proxy",
        ),
        (
            "Fuel mass shape",
            [as_float(row, "measuredMassRemainingKg") for row in rows],
            [as_float(row, "simMassProxy") for row in rows],
            "NIST derived mass",
            "CUDA mass proxy",
        ),
        (
            "Smoke optical depth shape",
            [as_float(row, "measuredSmokeOpticalDepth") for row in rows],
            [as_float(row, "simSmokeOpticalDepthProxy") for row in rows],
            "NIST smoke proxy",
            "CUDA smoke proxy",
        ),
        (
            "Radiant flux shape",
            [as_float(row, "measuredRadiantHeatFluxKWPerM2") for row in rows],
            [as_float(row, "simRadiantEnergyProxy") for row in rows],
            "NIST radiant flux",
            "CUDA radiant proxy",
        ),
    ]

    plt.rcParams.update(
        {
            "font.family": "DejaVu Sans",
            "figure.facecolor": "#101316",
            "axes.facecolor": "#15191d",
            "axes.edgecolor": "#59616b",
            "axes.labelcolor": "#e8edf2",
            "xtick.color": "#b7c0c8",
            "ytick.color": "#b7c0c8",
            "text.color": "#f3f5f7",
            "grid.color": "#333b44",
        }
    )

    fig, axes = plt.subplots(2, 2, figsize=(14, 8), dpi=140)
    fig.suptitle("Native FireSim CUDA vs NIST FCD Methanol_1m_Pool_R1", fontsize=17, fontweight="bold")
    for ax, (title, measured, simulated, measured_label, simulated_label) in zip(axes.flat, series):
        plot_series(ax, time, measured, simulated, title, measured_label, simulated_label)

    calibration = report.get("calibration", {})
    status = "PASS" if report.get("validationOk") else "FAIL"
    fig.text(
        0.5,
        0.02,
        f"validationOk={status} | "
        f"HRR RMSE={calibration.get('hrrShapeRmse', -1):.4f} | "
        f"Mass RMSE={calibration.get('massShapeRmse', -1):.4f} | "
        f"Smoke RMSE={calibration.get('smokeOpticalDepthShapeRmse', -1):.4f} | "
        f"Radiant RMSE={calibration.get('radiantHeatFluxShapeRmse', -1):.4f}",
        ha="center",
        color="#f7a431",
        fontsize=10,
    )
    fig.tight_layout(rect=(0, 0.05, 1, 0.95))
    path = output_dir / "sim-vs-nist-comparison.png"
    fig.savefig(path, bbox_inches="tight", facecolor=fig.get_facecolor())
    plt.close(fig)
    return path


def make_progress_gif(output_dir, rows):
    time = [as_float(row, "measuredTimeSeconds") for row in rows]
    measured_hrr = normalize([as_float(row, "measuredHrrKW") for row in rows])
    simulated_hrr = normalize([as_float(row, "simHrrProxy") for row in rows])
    frame_paths = []
    frame_count = 36
    for frame_index in range(frame_count):
        end = max(3, int(len(rows) * (frame_index + 1) / frame_count))
        fig, ax = plt.subplots(figsize=(8.8, 4.95), dpi=100)
        fig.patch.set_facecolor("#101316")
        ax.set_facecolor("#15191d")
        ax.plot(time[:end], measured_hrr[:end], color="#f7a431", linewidth=2.0, label="NIST HRR")
        ax.plot(time[:end], simulated_hrr[:end], color="#63d5ff", linewidth=1.8, label="CUDA HRR proxy")
        ax.set_xlim(time[0], time[-1])
        ax.set_ylim(-0.05, 1.05)
        ax.set_title("CUDA validation trace against NIST HRR", color="#f3f5f7")
        ax.set_xlabel("measured time (s)", color="#e8edf2")
        ax.set_ylabel("normalized shape", color="#e8edf2")
        ax.grid(True, color="#333b44", alpha=0.55)
        ax.legend(loc="upper right", frameon=False, fontsize=8)
        ax.tick_params(colors="#b7c0c8")
        for spine in ax.spines.values():
            spine.set_color("#59616b")
        fig.text(0.76, 0.88, f"t={time[end - 1]:.0f}s", color="#f7a431", fontsize=10)
        frame_path = output_dir / f"_calibration_trace_{frame_index:02d}.png"
        fig.savefig(frame_path, bbox_inches="tight", facecolor=fig.get_facecolor())
        plt.close(fig)
        frame_paths.append(frame_path)

    images = [Image.open(path).convert("P", palette=Image.Palette.ADAPTIVE, colors=128) for path in frame_paths]
    gif_path = output_dir / "sim-vs-nist-hrr.gif"
    images[0].save(gif_path, save_all=True, append_images=images[1:], duration=85, loop=0, optimize=True)
    for image in images:
        image.close()
    for path in frame_paths:
        path.unlink(missing_ok=True)
    return gif_path


def main():
    parser = argparse.ArgumentParser(description="Build Native FireSim calibration plots from CUDA validation outputs.")
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--manifest", default="")
    args = parser.parse_args()

    output_dir = Path(args.output_dir)
    comparison_path = output_dir / "calibration-comparison.csv"
    report_path = output_dir / "validation-report.json"
    if not comparison_path.exists():
        raise SystemExit(f"missing comparison CSV: {comparison_path}")
    if not report_path.exists():
        raise SystemExit(f"missing validation report: {report_path}")

    rows = read_csv(comparison_path)
    report = json.loads(report_path.read_text(encoding="utf-8"))
    static_path = make_static_plot(output_dir, rows, report)
    gif_path = make_progress_gif(output_dir, rows)

    index = {
        "manifest": args.manifest,
        "comparisonCsv": str(comparison_path),
        "validationReport": str(report_path),
        "staticPlot": str(static_path),
        "hrrGif": str(gif_path),
    }
    (output_dir / "artifact-index.json").write_text(json.dumps(index, indent=2), encoding="utf-8")
    print(static_path)
    print(gif_path)


if __name__ == "__main__":
    main()
