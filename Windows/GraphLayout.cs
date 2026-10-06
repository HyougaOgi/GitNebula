namespace GitNebula;
public record GraphEdge(int From, int To, int Color);
public record GraphRow(CommitRecord Commit, int Lane, int Color, int Width, GraphEdge[] Incoming, GraphEdge[] Outgoing);
public static class GraphLayout
{
    public static GraphRow[] Rows(CommitRecord[] commits)
    {
        var lanes = new List<string>(); var colors = new Dictionary<string, int>(); var next = 0;
        return commits.Select(commit => {
            var previous = lanes.ToArray();
            if (!lanes.Contains(commit.Id)) { lanes.Add(commit.Id); colors[commit.Id] = next++; }
            var before = lanes.ToArray(); var lane = lanes.IndexOf(commit.Id); var color = colors[commit.Id];
            lanes.RemoveAt(lane);
            for (var index = 0; index < commit.Parents.Length; index++) {
                var parent = commit.Parents[index];
                if (lanes.Contains(parent)) continue;
                lanes.Insert(Math.Min(lane + index, lanes.Count), parent); colors[parent] = index == 0 ? color : next++;
            }
            var incoming = previous.Select((id, index) => new GraphEdge(index, Array.IndexOf(before, id), colors[id])).ToArray();
            var outgoing = before.Select((id, index) => (id, index)).Where(x => x.id != commit.Id && lanes.Contains(x.id)).Select(x => new GraphEdge(x.index, lanes.IndexOf(x.id), colors[x.id]))
                .Concat(commit.Parents.Select(parent => new GraphEdge(lane, lanes.IndexOf(parent), colors[parent]))).ToArray();
            return new GraphRow(commit, lane, color, Math.Max(before.Length, lanes.Count), incoming, outgoing);
        }).ToArray();
    }
}
