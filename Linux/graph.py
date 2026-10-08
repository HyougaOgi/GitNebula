"""Git topology and spatial branch logs. The fourth dimension is commit time."""

from dataclasses import dataclass
import math


@dataclass(frozen=True)
class GraphRow:
    commit: object
    lane: int
    color: int
    incoming: tuple
    outgoing: tuple
    width: int


def graph_rows(commits):
    lanes, colors, previous, result = [], {}, [], []
    for commit in commits:
        if commit.id not in lanes:
            lanes.append(commit.id)
        if commit.id not in colors:
            colors[commit.id] = len(colors)
        before = lanes[:]
        lane = lanes.index(commit.id)
        color = colors[commit.id]
        incoming = tuple(
            (i, before.index(id), colors[id]) for i, id in enumerate(previous)
        )
        lanes.remove(commit.id)
        for offset, parent in enumerate(commit.parents):
            if parent not in lanes:
                lanes.insert(min(lane + offset, len(lanes)), parent)
            if parent not in colors:
                colors[parent] = color if offset == 0 else len(colors)
        outgoing = tuple(
            (i, lanes.index(id), colors[id])
            for i, id in enumerate(before)
            if id != commit.id and id in lanes
        ) + tuple(
            (lane, lanes.index(parent), colors[parent]) for parent in commit.parents
        )
        result.append(
            GraphRow(
                commit, lane, color, incoming, outgoing, max(len(before), len(lanes))
            )
        )
        previous = lanes[:]
    return result


@dataclass(frozen=True)
class BranchLog:
    id: int
    commits: tuple
    position: tuple
    names: tuple = ()

    @property
    def title(self):
        names = self.names or next(
            (commit_branch_names(c) for c in self.commits if commit_branch_names(c)), ()
        )
        return ", ".join(names) if names else self.commits[0].id if self.commits else ""

    @property
    def radius(self):
        return 0.22 + 0.16 * math.sqrt(len(self.commits))


def branch_names(decorations):
    names = []
    for ref in sorted(
        decorations.split(", "), key=lambda r: not r.startswith("HEAD -> ")
    ):
        name = ref.removeprefix("HEAD -> ")
        if not name or name == "HEAD" or name.startswith(("tag: ", "refs/tags/")):
            continue
        if name.startswith("refs/") and not name.startswith(
            ("refs/heads/", "refs/remotes/")
        ):
            continue
        local = ref.startswith("HEAD -> ") or name.startswith("refs/heads/")
        for prefix in ("refs/heads/", "refs/remotes/"):
            if name.startswith(prefix):
                name = name[len(prefix) :]
                break
        if not local and name.endswith("/HEAD") and len(name.split("/")) == 2:
            continue
        if name not in names:
            names.append(name)
    return tuple(names)


def commit_branch_names(commit):
    if commit.branch_names is None:
        return branch_names(commit.decorations)
    head = next(
        (r[8:] for r in commit.decorations.split(", ") if r.startswith("HEAD -> ")),
        None,
    )
    if head in commit.branch_names:
        return (head,) + tuple(n for n in commit.branch_names if n != head)
    return commit.branch_names


def branch_logs(commits):
    records = {c.id: c for c in commits}
    assigned = set()
    groups = []

    def priority(c):
        return (
            0
            if "HEAD -> " in c.decorations or c.decorations == "HEAD"
            else (1 if commit_branch_names(c) else 2)
        )

    for root in sorted(
        enumerate(commits), key=lambda item: (priority(item[1]), item[0])
    ):
        current = root[1]
        ids = set()
        if current.id in assigned:
            continue
        while current and current.id not in assigned:
            assigned.add(current.id)
            ids.add(current.id)
            current = records.get(current.parents[0]) if current.parents else None
        groups.append(tuple(c for c in commits if c.id in ids))
    radius = max(6, len(groups) ** (1 / 3) * 3)
    points = [
        (
            math.cos(i * 2.39996) * radius * (0.45 + (i % 3) * 0.18),
            math.sin(i * 1.73) * radius * 0.65,
            math.sin(i * 2.39996) * radius * (0.5 + (i % 5) * 0.1),
        )
        for i in range(len(groups))
    ]
    if points:
        center = tuple(sum(p[a] for p in points) / len(points) for a in range(3))
        points = [tuple(p[a] - center[a] for a in range(3)) for p in points]
    names = {c.id: commit_branch_names(c) for c in commits}
    children = {}
    for c in commits:
        for parent in c.parents:
            children.setdefault(parent, []).append(c.id)

    def resolve_names(group):
        direct = next((names[c.id] for c in group if names[c.id]), ())
        if direct:
            return direct
        # Merged logs use the nearest surviving branch containing their tip.
        frontier = [group[0].id] if group else []
        visited = set(frontier)
        while frontier:
            labels = tuple(dict.fromkeys(n for id in frontier for n in names[id]))
            if labels:
                return labels
            following = []
            for id in frontier:
                for child in children.get(id, ()):
                    if child not in visited:
                        visited.add(child)
                        following.append(child)
            frontier = following
        return ()

    return tuple(
        BranchLog(i, group, points[i], resolve_names(group))
        for i, group in enumerate(groups)
    )


def branch_links(branches):
    membership = {c.id: b.id for b in branches for c in b.commits}
    links = {}
    for branch in branches:
        for commit in branch.commits:
            for parent in commit.parents:
                if parent in membership and membership[parent] != branch.id:
                    pair = tuple(sorted((branch.id, membership[parent])))
                    links.setdefault(pair, []).append((commit.id, parent))
    return links


class OrbitCamera:
    def __init__(self):
        self.base_distance = 32.0
        self.reset()

    def reset(self):
        self.yaw, self.pitch, self.scroll, self.target = 0.0, 0.12, 0.0, (0.0, 0.0, 0.0)

    @property
    def distance(self):
        return self.base_distance * math.exp(max(-8, min(8, self.scroll)) * 0.12)

    def zoom(self, amount):
        self.scroll += amount

    def rotate(self, dx, dy):
        self.yaw += dx * 0.007
        self.pitch = max(-1.5, min(1.5, self.pitch + dy * 0.007))

    def transform(self, point):
        x, y, z = (point[a] - self.target[a] for a in range(3))
        cy, sy, cp, sp = (
            math.cos(self.yaw),
            math.sin(self.yaw),
            math.cos(self.pitch),
            math.sin(self.pitch),
        )
        x, z = cy * x - sy * z, sy * x + cy * z
        return x, cp * y - sp * z, sp * y + cp * z

    def inverse(self, point):
        x, y, z = point
        cy, sy, cp, sp = (
            math.cos(self.yaw),
            math.sin(self.yaw),
            math.cos(self.pitch),
            math.sin(self.pitch),
        )
        y, z = cp * y + sp * z, -sp * y + cp * z
        return tuple(
            v + self.target[a]
            for a, v in enumerate((cy * x + sy * z, y, -sy * x + cy * z))
        )

    def project(self, point, width, height):
        x, y, z = self.transform(point)
        depth = self.distance - z
        if depth <= 0.05:
            return None
        scale = min(width, height) * 1.15 / depth
        return width * 0.5 + x * scale, height * 0.5 - y * scale, scale


PALETTE = (
    (0.57, 0.3, 1),
    (0.2, 0.7, 1),
    (1, 0.3, 0.62),
    (0.3, 0.95, 0.73),
    (1, 0.65, 0.25),
    (0.5, 0.4, 1),
)


def volume_pixels(camera, width=128, height=80, time=0, aspect=None):
    """Ray march an XYZ density field. Rotation changes the sampled volume itself."""
    aspect = aspect or width / height
    pixels = bytearray(width * height * 4)
    center_depth = camera.distance - camera.transform((0, 0, 0))[2]
    near = max(0.08, center_depth - 24)
    stride = max(0, center_depth + 24 - near) / 28
    for y in range(height):
        for x in range(width):
            dx = (x / width - 0.5) * aspect / min(aspect, 1) / 1.15
            dy = -(y / height - 0.5) / min(aspect, 1) / 1.15
            r, g, b, opacity = 0.024, 0.032, 0.065, 0.0
            for step in range(28):
                depth = near + (step + 0.5) * stride
                px, py, pz = camera.inverse(
                    (dx * depth, dy * depth, camera.distance - depth)
                )
                envelope = math.exp(
                    -((px / 11) ** 2 + (py / 7) ** 2 + (pz / 10) ** 2) * 1.6
                )
                if envelope < 0.01:
                    continue
                noise = (
                    math.sin(px * 0.65 + time * 0.12)
                    * math.sin(py * 0.8 - time * 0.09)
                    * math.sin(pz * 0.7 + time * 0.07)
                )
                filament = abs(
                    math.sin(px * 0.31 + py * 0.55 + pz * 0.43 + noise * 2.4)
                )
                density = envelope * max(0, filament - 0.3) * 0.13 * stride / 1.8
                dust = 0.3 + 0.7 * max(
                    0, math.sin(px * 0.75 - py * 0.37 + pz * 0.8 + noise)
                )
                hue = 0.5 + 0.5 * math.sin(px * 0.17 + pz * 0.2 + time * 0.03)
                weight = (1 - opacity) * density
                r += weight * (0.25 + 0.65 * hue) * dust
                g += weight * (0.27 + 0.35 * (1 - hue)) * dust
                b += weight * 0.95 * dust
                opacity += weight
            index = (y * width + x) * 4
            pixels[index : index + 4] = bytes(
                (
                    min(255, int(b * 255)),
                    min(255, int(g * 255)),
                    min(255, int(r * 255)),
                    255,
                )
            )
    return pixels
