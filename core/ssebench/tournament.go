package ssebench

import (
	"context"
	"sort"
	"time"
)

// Relay idle timeouts close with FIN/RST, so deaths are seen passively; Since
// is the entrant's last traffic, where its relay idle timer starts.
type Entrant struct {
	LatencyMs float64
	Since     time.Time
	Closed    func() bool
}

type Placement struct {
	Index    int
	IdleMs   float64
	Survived bool
	Place    int
}

type Rules struct {
	Limit time.Duration
	Poll  time.Duration
	// Tie groups near-simultaneous deaths of relays sharing a timeout; latency
	// ranks inside a group, including a last survivor that barely outlived it.
	Tie time.Duration
	// BandMs keeps tied entrants equal below this gap; PING retests vary ~3-4 ms.
	BandMs float64
}

var DefaultRules = Rules{Limit: 15 * time.Minute, Poll: time.Second, Tie: 5 * time.Second, BandMs: 15}

func Tournament(ctx context.Context, entrants []Entrant, rules Rules, fallen func(index int, idle time.Duration)) []Placement {
	start := time.Now()
	since := make([]time.Time, len(entrants))
	for i, e := range entrants {
		since[i] = e.Since
		if since[i].IsZero() {
			since[i] = start
		}
	}
	idle := make([]time.Duration, len(entrants))
	alive := make([]bool, len(entrants))
	count := len(entrants)
	for i := range alive {
		alive[i] = true
	}
	grace := time.Duration(-1)
	ticker := time.NewTicker(rules.Poll)
	defer ticker.Stop()
watch:
	for count > 0 {
		elapsed := time.Since(start)
		for i, e := range entrants {
			if alive[i] && e.Closed() {
				alive[i], idle[i] = false, time.Since(since[i])
				count--
				if fallen != nil {
					fallen(i, idle[i])
				}
			}
		}
		if count == 0 || elapsed >= rules.Limit || (grace >= 0 && elapsed >= grace) {
			break
		}
		if count == 1 && grace < 0 {
			grace = elapsed + rules.Tie
		}
		select {
		case <-ctx.Done():
			break watch
		case <-ticker.C:
		}
	}
	end := time.Now()
	placements := make([]Placement, len(entrants))
	for i := range entrants {
		placements[i] = Placement{Index: i, IdleMs: millis(idle[i])}
		if alive[i] {
			placements[i].IdleMs, placements[i].Survived = millis(end.Sub(since[i])), true
		}
	}
	sort.SliceStable(placements, func(a, b int) bool { return placements[a].IdleMs > placements[b].IdleMs })
	latency := func(p Placement) float64 { return entrants[p.Index].LatencyMs }
	tie := millis(rules.Tie)
	for lo := 0; lo < len(placements); {
		hi := lo + 1
		for hi < len(placements) && placements[hi-1].IdleMs-placements[hi].IdleMs < tie {
			hi++
		}
		group := placements[lo:hi]
		sort.SliceStable(group, func(a, b int) bool { return latency(group[a]) < latency(group[b]) })
		for band := 0; band < len(group); {
			next := band + 1
			for next < len(group) && latency(group[next])-latency(group[band]) < rules.BandMs {
				next++
			}
			for i := band; i < next; i++ {
				group[i].Place = lo + band + 1
			}
			band = next
		}
		lo = hi
	}
	return placements
}

func Points(placements []Placement) []float64 {
	points := make([]float64, len(placements))
	for lo := 0; lo < len(placements); {
		hi := lo + 1
		for hi < len(placements) && placements[hi].Place == placements[lo].Place {
			hi++
		}
		total := 0.0
		for i := lo; i < hi && i < len(Awards); i++ {
			total += float64(Awards[i])
		}
		for i := lo; i < hi; i++ {
			points[i] = total / float64(hi-lo)
		}
		lo = hi
	}
	return points
}
