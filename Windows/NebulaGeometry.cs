using System.Numerics;
namespace GitNebula;

public record NebulaBranch(int Id, CommitRecord[] Commits, Vector3 Position, string[]? Names = null)
{
    public double Radius => .22 + .16 * Math.Sqrt(Commits.Length);
    public string Title {
        get {
            var names = Names ?? Commits.Select(NamesFor).FirstOrDefault(n => n.Length > 0) ?? [];
            return names.Length == 0 ? Commits.FirstOrDefault()?.Id ?? "" : string.Join(", ", names);
        }
    }
    public static string[] BranchNames(string decorations)
    {
        var refs = decorations.Split(", "); var result = new List<string>();
        foreach (var reference in refs.OrderBy(r => r.StartsWith("HEAD -> ", StringComparison.Ordinal) ? 0 : 1)) {
            var name = reference.StartsWith("HEAD -> ", StringComparison.Ordinal) ? reference[8..] : reference;
            if (name.Length == 0 || name == "HEAD" || name.StartsWith("tag: ", StringComparison.Ordinal) || name.StartsWith("refs/tags/", StringComparison.Ordinal)) continue;
            if (name.StartsWith("refs/", StringComparison.Ordinal) && !name.StartsWith("refs/heads/", StringComparison.Ordinal) && !name.StartsWith("refs/remotes/", StringComparison.Ordinal)) continue;
            var local = reference.StartsWith("HEAD -> ", StringComparison.Ordinal) || name.StartsWith("refs/heads/", StringComparison.Ordinal);
            foreach (var prefix in new[] { "refs/heads/", "refs/remotes/" }) if (name.StartsWith(prefix, StringComparison.Ordinal)) { name = name[prefix.Length..]; break; }
            if (!local && name.EndsWith("/HEAD", StringComparison.Ordinal) && name.Split('/').Length == 2) continue;
            if (!result.Contains(name)) result.Add(name);
        }
        return result.ToArray();
    }
    private static string[] NamesFor(CommitRecord commit) {
        if (commit.BranchNames is not { } actual) return BranchNames(commit.Decorations);
        var head = commit.Decorations.Split(", ").FirstOrDefault(r => r.StartsWith("HEAD -> ", StringComparison.Ordinal))?[8..];
        return head != null && actual.Contains(head) ? new[] { head }.Concat(actual.Where(n => n != head)).ToArray() : actual;
    }
    public static NebulaBranch[] Group(CommitRecord[] commits)
    {
        var records = commits.ToDictionary(c => c.Id); var assigned = new HashSet<string>(); var groups = new List<CommitRecord[]>();
        int Priority(CommitRecord c) => c.Decorations.Contains("HEAD -> ", StringComparison.Ordinal) || c.Decorations == "HEAD" ? 0 : NamesFor(c).Length > 0 ? 1 : 2;
        foreach (var root in commits.Select((c, i) => (c, i)).OrderBy(p => Priority(p.c)).ThenBy(p => p.i).Select(p => p.c)) {
            if (assigned.Contains(root.Id)) continue;
            var ids = new HashSet<string>(); CommitRecord? current = root;
            while (current != null && assigned.Add(current.Id)) { ids.Add(current.Id); current = current.Parents.Length == 0 ? null : records.GetValueOrDefault(current.Parents[0]); }
            groups.Add(commits.Where(c => ids.Contains(c.Id)).ToArray());
        }
        var radius = Math.Max(6, Math.Cbrt(groups.Count) * 3);
        var points = groups.Select((_, i) => new Vector3((float)(Math.Cos(i * 2.39996) * radius * (.45 + i % 3 * .18)), (float)(Math.Sin(i * 1.73) * radius * .65), (float)(Math.Sin(i * 2.39996) * radius * (.5 + i % 5 * .1)))).ToArray();
        var center = points.Length == 0 ? Vector3.Zero : points.Aggregate(Vector3.Zero, (sum, p) => sum + p) / points.Length;
        var names = commits.ToDictionary(c => c.Id, NamesFor);
        var children = commits.SelectMany(c => c.Parents.Select(p => (Parent: p, Child: c.Id))).GroupBy(e => e.Parent).ToDictionary(g => g.Key, g => g.Select(e => e.Child).ToArray());
        string[] ResolveNames(CommitRecord[] group) {
            var direct = group.Select(c => names[c.Id]).FirstOrDefault(n => n.Length > 0);
            if (direct != null) return direct;
            var frontier = group.Take(1).Select(c => c.Id).ToArray(); var visited = frontier.ToHashSet();
            while (frontier.Length > 0) {
                var labels = frontier.SelectMany(id => names[id]).Distinct().ToArray();
                if (labels.Length > 0) return labels;
                frontier = frontier.SelectMany(id => children.GetValueOrDefault(id) ?? []).Where(visited.Add).ToArray();
            }
            return [];
        }
        return groups.Select((c, i) => new NebulaBranch(i, c, points[i] - center, ResolveNames(c))).ToArray();
    }
    public static Dictionary<(int A, int B), List<(string Child, string Parent)>> Links(NebulaBranch[] branches)
    {
        var membership = branches.SelectMany(b => b.Commits.Select(c => (c.Id, b.Id))).ToDictionary(p => p.Item1, p => p.Item2);
        var links = new Dictionary<(int, int), List<(string, string)>>();
        foreach (var branch in branches) foreach (var commit in branch.Commits) foreach (var parent in commit.Parents) {
            if (!membership.TryGetValue(parent, out var other) || other == branch.Id) continue;
            var key = (Math.Min(branch.Id, other), Math.Max(branch.Id, other));
            if (!links.TryGetValue(key, out var values)) links[key] = values = new();
            values.Add((commit.Id, parent));
        }
        return links;
    }
}

public sealed class OrbitCamera
{
    public double Yaw, Pitch = .12, Scroll;
    public Vector3 Target;
    public double BaseDistance = 32;
    public double Distance => BaseDistance * Math.Exp(Math.Clamp(Scroll, -8, 8) * .12);
    public void Reset() { Yaw = Scroll = 0; Pitch = .12; Target = Vector3.Zero; }
    public void Zoom(double amount) => Scroll += amount;
    public void Rotate(double x, double y) { Yaw += x * .007; Pitch = Math.Clamp(Pitch + y * .007, -1.5, 1.5); }
    public OrbitCamera Copy() => new() { Yaw = Yaw, Pitch = Pitch, Scroll = Scroll, Target = Target, BaseDistance = BaseDistance };
    public Vector3 Transform(Vector3 point)
    {
        point -= Target;
        var x = Math.Cos(Yaw) * point.X - Math.Sin(Yaw) * point.Z; var z = Math.Sin(Yaw) * point.X + Math.Cos(Yaw) * point.Z;
        return new((float)x, (float)(Math.Cos(Pitch) * point.Y - Math.Sin(Pitch) * z), (float)(Math.Sin(Pitch) * point.Y + Math.Cos(Pitch) * z));
    }
    public Vector3 Inverse(double x, double y, double z)
    {
        var py = Math.Cos(Pitch) * y + Math.Sin(Pitch) * z; var pz = -Math.Sin(Pitch) * y + Math.Cos(Pitch) * z;
        return new Vector3((float)(Math.Cos(Yaw) * x + Math.Sin(Yaw) * pz), (float)py, (float)(-Math.Sin(Yaw) * x + Math.Cos(Yaw) * pz)) + Target;
    }
    public (double X, double Y, double Scale)? Project(Vector3 point, double width, double height)
    {
        var p = Transform(point); var depth = Distance - p.Z;
        if (depth <= .05) return null;
        var scale = Math.Min(width, height) * 1.15 / depth;
        return (width / 2 + p.X * scale, height / 2 - p.Y * scale, scale);
    }
}

public static class NebulaVolume
{
    public static byte[] Pixels(OrbitCamera camera, int width = 128, int height = 80, double time = 0, double? aspectRatio = null)
    {
        var pixels = new byte[width * height * 4]; var aspect = aspectRatio ?? (double)width / height;
        var centerDepth = camera.Distance - camera.Transform(Vector3.Zero).Z;
        var near = Math.Max(.08, centerDepth - 24); var stride = Math.Max(0, centerDepth + 24 - near) / 28;
        Parallel.For(0, height, y => {
            for (var x = 0; x < width; x++) {
                var dx = ((double)x / width - .5) * aspect / Math.Min(aspect, 1) / 1.15; var dy = -((double)y / height - .5) / Math.Min(aspect, 1) / 1.15;
                double r = .024, g = .032, b = .065, opacity = 0;
                for (var step = 0; step < 28; step++) {
                    var depth = near + (step + .5) * stride; var p = camera.Inverse(dx * depth, dy * depth, camera.Distance - depth);
                    var envelope = Math.Exp(-(Math.Pow(p.X / 11, 2) + Math.Pow(p.Y / 7, 2) + Math.Pow(p.Z / 10, 2)) * 1.6);
                    if (envelope < .01) continue;
                    var noise = Math.Sin(p.X * .65 + time * .12) * Math.Sin(p.Y * .8 - time * .09) * Math.Sin(p.Z * .7 + time * .07);
                    var filament = Math.Abs(Math.Sin(p.X * .31 + p.Y * .55 + p.Z * .43 + noise * 2.4));
                    var density = envelope * Math.Max(0, filament - .3) * .13 * stride / 1.8; var dust = .3 + .7 * Math.Max(0, Math.Sin(p.X * .75 - p.Y * .37 + p.Z * .8 + noise));
                    var hue = .5 + .5 * Math.Sin(p.X * .17 + p.Z * .2 + time * .03); var weight = (1 - opacity) * density;
                    r += weight * (.25 + .65 * hue) * dust; g += weight * (.27 + .35 * (1 - hue)) * dust; b += weight * .95 * dust; opacity += weight;
                }
                var index = (y * width + x) * 4;
                pixels[index] = (byte)Math.Min(255, b * 255); pixels[index + 1] = (byte)Math.Min(255, g * 255); pixels[index + 2] = (byte)Math.Min(255, r * 255); pixels[index + 3] = 255;
            }
        });
        return pixels;
    }
}
