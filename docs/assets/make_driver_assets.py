"""Generate conceptual README diagrams. No hardware is accessed.

Usage: python docs/assets/make_driver_assets.py
"""

from html import escape
from pathlib import Path

HERE = Path(__file__).resolve().parent
BG, FG, MUTED, GRID = '#101820', '#f0f6fc', '#a5b4c5', '#344352'
AMBER, BLUE = '#f0b86e', '#64b5f6'
FONT = "-apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif"


def start(height, title, desc):
    return [f'<svg xmlns="http://www.w3.org/2000/svg" width="1200" height="{height}" viewBox="0 0 1200 {height}" role="img" aria-labelledby="title desc">',
            f'  <title id="title">{escape(title)}</title>',
            f'  <desc id="desc">{escape(desc)}</desc>',
            f'  <rect width="1200" height="{height}" rx="12" fill="{BG}"/>',
            f'  <g font-family="{FONT}">']


def text(x, y, value, size=22, color=FG, weight=400, anchor='start'):
    return f'    <text x="{x}" y="{y}" font-size="{size}" fill="{color}" font-weight="{weight}" text-anchor="{anchor}">{escape(str(value))}</text>'


def line(x1, y1, x2, y2, color=GRID, width=1):
    return f'    <line x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}" stroke="{color}" stroke-width="{width}"/>'


def save(name, parts):
    (HERE / name).write_text('\n'.join([*parts, '  </g>', '</svg>', '']), encoding='utf-8', newline='\n')


def bring_up():
    s = start(350, 'Gaudi2 OAM to working HPU',
              'Conceptual bring-up stages on the documented adapter setup: PCIe enumeration, '
              'patched-driver initialization with identity IOMMU mapping, and compute validation. This is not a wiring diagram.')
    s += [text(56, 48, 'GAUDI2 HL-225 / HARDWARE BRING-UP', 20, AMBER, 600),
          text(1144, 48, 'UBUNTU · 1.24.1', 20, MUTED, anchor='end'),
          text(56, 117, 'From OAM to a working HPU.', 56, weight=650),
          text(56, 159, 'Adapter setup · driver patches · documented compute checks', 25, MUTED)]
    for x, num, heading, sub in [(56, '01', 'Enumerate', 'OAM → PCIe adapter'),
                                  (448, '02', 'Initialize', 'Patched driver + identity'),
                                  (840, '03', 'Validate', 'Matmul + forward/backward')]:
        s += [line(x, 200, x+304, 200, AMBER, 2),
              text(x, 239, num, 23, AMBER, 600),
              text(x+50, 239, heading, 28, weight=600), text(x, 280, sub, 22, MUTED)]
    s.append(text(56, 324, 'Conceptual sequence · inspect power, seating, and IOMMU before device acquisition', 20, MUTED))
    save('bring-up-path.svg', s)


def iommu():
    s = start(560, 'Diagnosed IOMMU address mismatch',
              'Repository investigation: in the translated DMA-FQ domain, an IOVA is treated as a physical address '
              'by the host-resident PMMU page-table path, leading to corruption on the tested host. '
              'The tested workaround uses iommu=pt and verifies an identity domain.')
    s += [text(56, 54, 'One address assumption. Two outcomes.', 38, weight=650),
          text(56, 94, 'Gaudi 1.24.1 · host-resident PMMU tables · tested-platform diagnosis', 23, MUTED)]
    for yy, accent, label, left, middle, right in [
        (152, AMBER, 'TRANSLATED DOMAIN / DMA-FQ', 'DMA address / IOVA', 'Treated as physical', 'Page-table corruption'),
        (324, BLUE, 'TESTED WORKAROUND / IDENTITY', 'iommu=pt', 'DMA = physical', 'Compute checks pass'),
    ]:
        s += [line(56, yy, 1144, yy, GRID), text(56, yy+34, label, 20, accent, 600)]
        for x, value in [(56,left),(448,middle),(840,right)]:
            s.append(text(x, yy+88, value, 27, weight=600))
        for x in (374,766):
            s += [line(x, yy+79, x+34, yy+79, accent, 2),
                  f'    <path d="M{x+26} {yy+72} L{x+34} {yy+79} L{x+26} {yy+86}" fill="none" stroke="{accent}" stroke-width="2"/>']
        s.append(text(56, yy+127,
                      'Recorded failure during HPU acquisition' if yy == 152 else 'Verify the active device group is identity before acquiring the HPU',
                      22, MUTED))
    s += [line(56, 488, 1144, 488), text(56, 528, 'Source: repository investigation and final solution · not a universal platform claim', 20, MUTED)]
    save('iommu-address-path.svg', s)


if __name__ == '__main__':
    bring_up()
    iommu()
    print('Generated two driver-guide assets.')
