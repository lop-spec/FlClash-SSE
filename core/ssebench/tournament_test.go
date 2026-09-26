package ssebench

import (
	"context"
	"testing"
	"time"
)

var quick = Rules{Limit: 2 * time.Second, Poll: 5 * time.Millisecond, Tie: 60 * time.Millisecond}

func dies(start time.Time, after time.Duration) func() bool {
	return func() bool { return after > 0 && time.Since(start) >= after }
}

func order(placements []Placement) []int {
	out := make([]int, len(placements))
	for i, p := range placements {
		out[i] = p.Index
	}
	return out
}

func same(a, b []int) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

func TestTournamentRanksByIdleLifetimeAndStopsAfterTheLastSurvivor(t *testing.T) {
	start := time.Now()
	entrants := []Entrant{
		{LatencyMs: 100, Closed: dies(start, 100*time.Millisecond)},
		{LatencyMs: 300, Closed: dies(start, 0)},
		{LatencyMs: 200, Closed: dies(start, 400*time.Millisecond)},
		{LatencyMs: 50, Closed: dies(start, 250*time.Millisecond)},
	}
	var fallen []int
	placements := Tournament(context.Background(), entrants, quick, func(i int, _ time.Duration) { fallen = append(fallen, i) })
	if got := order(placements); !same(got, []int{1, 2, 3, 0}) {
		t.Fatalf("order %v", got)
	}
	if !placements[0].Survived || placements[1].Survived || !same(fallen, []int{0, 3, 2}) {
		t.Fatalf("placements %+v fallen %v", placements, fallen)
	}
	if elapsed := time.Since(start); elapsed > 400*time.Millisecond+quick.Tie+200*time.Millisecond {
		t.Fatalf("tournament kept running after the winner was decided: %v", elapsed)
	}
	if d := placements[1].IdleMs; d < 400 || d > 500 {
		t.Fatalf("idle lifetime %v", d)
	}
}

func TestTournamentBreaksNearSimultaneousDeathsByLatency(t *testing.T) {
	start := time.Now()
	entrants := []Entrant{
		{LatencyMs: 300, Closed: dies(start, 200*time.Millisecond)},
		{LatencyMs: 100, Closed: dies(start, 220*time.Millisecond)},
		{LatencyMs: 200, Closed: dies(start, 80*time.Millisecond)},
	}
	placements := Tournament(context.Background(), entrants, quick, nil)
	if got := order(placements); !same(got, []int{1, 0, 2}) {
		t.Fatalf("the last two died within the tie window, latency must decide: %v", got)
	}
	start = time.Now()
	entrants = []Entrant{
		{LatencyMs: 100, Closed: dies(start, 200*time.Millisecond)},
		{LatencyMs: 300, Closed: dies(start, 230*time.Millisecond)},
	}
	if got := order(Tournament(context.Background(), entrants, quick, nil)); !same(got, []int{0, 1}) {
		t.Fatalf("a survivor that outlives the last death by less than the tie window is not a clear winner: %v", got)
	}
}

func TestTournamentMeasuresEachEntrantFromItsOwnStart(t *testing.T) {
	start := time.Now()
	entrants := []Entrant{
		{LatencyMs: 100, Since: start.Add(-300 * time.Millisecond), Closed: dies(start, 150*time.Millisecond)},
		{LatencyMs: 200, Closed: dies(start, 300*time.Millisecond)},
	}
	placements := Tournament(context.Background(), entrants, quick, nil)
	if got := order(placements); !same(got, []int{0, 1}) || placements[0].IdleMs < 440 {
		t.Fatalf("idle lifetime must count from each connection's last traffic: %+v", placements)
	}
}

func TestTournamentLimitRanksSurvivorsByLatency(t *testing.T) {
	rules := quick
	rules.Limit = 80 * time.Millisecond
	start := time.Now()
	entrants := []Entrant{
		{LatencyMs: 300, Closed: dies(start, 0)},
		{LatencyMs: 100, Closed: dies(start, 0)},
		{LatencyMs: 200, Closed: dies(start, 0)},
	}
	placements := Tournament(context.Background(), entrants, rules, nil)
	if got := order(placements); !same(got, []int{1, 2, 0}) || !placements[2].Survived {
		t.Fatalf("order %v", got)
	}
	if elapsed := time.Since(start); elapsed > time.Second {
		t.Fatalf("limit ignored: %v", elapsed)
	}
}

func TestTournamentHandlesNoEntrantsAndCancellation(t *testing.T) {
	if got := Tournament(context.Background(), nil, quick, nil); len(got) != 0 {
		t.Fatalf("got %v", got)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()
	start := time.Now()
	placements := Tournament(ctx, []Entrant{{Closed: dies(start, 0)}, {Closed: dies(start, 0)}}, quick, nil)
	if time.Since(start) > time.Second || len(placements) != 2 || !placements[0].Survived {
		t.Fatalf("cancellation not honoured: %+v", placements)
	}
}

func TestTournamentSharesPlacesWithinTheLatencyBand(t *testing.T) {
	rules := quick
	rules.BandMs = 15
	rules.Limit = 80 * time.Millisecond
	start := time.Now()
	entrants := []Entrant{
		{LatencyMs: 150, Closed: dies(start, 0)},
		{LatencyMs: 140, Closed: dies(start, 0)},
		{LatencyMs: 158, Closed: dies(start, 0)},
		{LatencyMs: 230, Closed: dies(start, 0)},
		{LatencyMs: 90, Closed: dies(start, 10*time.Millisecond)},
	}
	placements := Tournament(context.Background(), entrants, rules, nil)
	places := make([]int, len(placements))
	for i, p := range placements {
		places[i] = p.Place
	}
	if got := order(placements); !same(got, []int{1, 0, 2, 3, 4}) || !same(places, []int{1, 1, 3, 4, 5}) {
		t.Fatalf("order %v places %v", got, places)
	}
	points := Points(placements)
	want := []float64{3.5, 3.5, 2, 1, 0}
	for i := range want {
		if points[i] != want[i] {
			t.Fatalf("points %v, want %v", points, want)
		}
	}
}

func TestPointsSplitTheAwardsOfASharedPlace(t *testing.T) {
	five := []Placement{{Place: 1}, {Place: 1}, {Place: 1}, {Place: 1}, {Place: 1}}
	for _, p := range Points(five) {
		if p != 2 {
			t.Fatalf("five equal entrants share 10 points: %v", Points(five))
		}
	}
	solo := Points([]Placement{{Place: 1}, {Place: 2}, {Place: 3}})
	if solo[0] != 4 || solo[1] != 3 || solo[2] != 2 {
		t.Fatalf("distinct places keep their awards: %v", solo)
	}
}
