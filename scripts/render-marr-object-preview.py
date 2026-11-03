#!/usr/bin/env python3
"""Record the native Rive object scenes; no raster compositing or retouching."""
import argparse
import os
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / 'DesignAssets/MarrObjectStudies'
OUTPUT = ROOT / 'output/marr-object-preview'
CLI = Path('/tmp/marr-rive-tools/bin/rive')


def render(stem, artboard):
    frames = OUTPUT / f'{stem}-frames'
    frames.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ, RIVE_HOME='/tmp/marr-rive-tools')
    for frame in range(72):
        subprocess.run([str(CLI), str(PROJECT), f'--artboard={artboard}',
                        f'--advance={frame * 5}', f'--screenshot={frames}/{frame:04d}.png'],
                       env=env, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if frame % 24 == 0:
            print(f'{stem}: {frame + 1}/72', flush=True)
    subprocess.run(['ffmpeg', '-y', '-loglevel', 'error', '-framerate', '12',
                    '-i', str(frames / '%04d.png'), '-filter_complex',
                    'split[a][b];[a]palettegen[p];[b][p]paletteuse', '-loop', '0',
                    str(OUTPUT / f'{stem}.gif')], check=True)
    subprocess.run(['ffmpeg', '-y', '-loglevel', 'error', '-framerate', '12',
                    '-i', str(frames / '%04d.png'), '-c:v', 'libx264',
                    '-pix_fmt', 'yuv420p', '-movflags', '+faststart',
                    str(OUTPUT / f'{stem}.mp4')], check=True)
    shutil.copy2(frames / '0012.png', OUTPUT / f'{stem}.png')
    print(f'{stem}: complete', flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--only', choices=['gallery', 'reading'])
    parser.add_argument('--output', type=Path, default=OUTPUT)
    args = parser.parse_args()
    OUTPUT = args.output.resolve()
    if not CLI.exists():
        raise SystemExit('Rive CLI is required at /tmp/marr-rive-tools/bin/rive')
    if args.only != 'reading':
        render('marr-objects', 'Marr object studies')
    if args.only != 'gallery':
        render('marr-reading', 'Translation detail')
