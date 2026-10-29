package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"log/slog"
	"path"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Plan → preview → apply (docs/storage-layer.md §2). A request is an Intent; the planner turns it into
// a Plan from a fresh look at the machine: the steps in words and as exact argument vectors, what it
// does to capacity and protection, which disks it erases, and what must be typed to confirm. Applying
// makes the plan again from a new look and runs it only when nothing changed; it then runs as a Job.
//
// Every argument of every command is a literal, a path from the fresh listing (a drive the request
// named and the listing offers for that verb), the pool's mount point or md device, or a number.
// Nothing a request carries reaches a command line otherwise.

// Intent is what a person asks for.
type Intent struct {
	Verb   string   `json:"verb"`
	Layout *Layout  `json:"layout,omitempty"`
	Disks  []string `json:"disks,omitempty"`  // drive names (vdb)
	Member string   `json:"member,omitempty"` // a pool member's name (vdc, "devid 2")
}

// Effects is what a plan does.
type Effects struct {
	CapacityBefore  uint64   `json:"capacity_before"`
	CapacityAfter   uint64   `json:"capacity_after"`
	ToleratesBefore int      `json:"tolerates_before"`
	ToleratesAfter  int      `json:"tolerates_after"`
	Erases          []string `json:"erases"` // drives whose content is destroyed
	// Background: the work goes on after the steps ran (a rebuild, a conversion, a reshape, a check);
	// its progress shows on the pool.
	Background bool     `json:"background"`
	Notes      []string `json:"notes"`
}

// Plan is a previewed change.
type Plan struct {
	ID       string     `json:"id"`
	Intent   Intent     `json:"intent"`
	Summary  string     `json:"summary"`
	Steps    []string   `json:"steps"`
	Commands [][]string `json:"commands"` // the exact commands, for the advanced view
	Effects  Effects    `json:"effects"`
	Confirm  string     `json:"confirm"` // to be typed to apply; "" needs none
	Expires  time.Time  `json:"expires"`

	steps []step
}

type step struct {
	text string
	argv []string
	// wait, when set, runs after argv (or alone): long kernel work the next step needs done
	wait func(ctx context.Context) error
}

// Job is an applied plan.
type Job struct {
	ID      string     `json:"id"`
	Verb    string     `json:"verb"`
	Summary string     `json:"summary"`
	State   string     `json:"state"` // running, done, failed
	Step    int        `json:"step"`  // steps finished
	Steps   int        `json:"steps"`
	Error   string     `json:"error,omitempty"`
	Started time.Time  `json:"started"`
	Ended   *time.Time `json:"ended,omitempty"`
}

// refusal is a request that cannot be planned: the message says why, for the person.
type refusal struct{ msg string }

func (r refusal) Error() string { return r.msg }

func refuse(format string, args ...any) error { return refusal{fmt.Sprintf(format, args...)} }

var (
	errNoPlan    = errors.New("no such plan (it expired, or was applied)")
	errStalePlan = refusal{"the storage changed since this plan was made: look at it again"}
	errBusy      = refusal{"another storage change is still running"}
	errConfirm   = refusal{"the confirmation does not match"}
)

const planTTL = 10 * time.Minute

// Planner makes and applies plans; one job at a time.
type Planner struct {
	inv    *Inventory
	run    Runner // for the steps: no short timeout (mkfs, device remove)
	online *Creator
	log    *slog.Logger
	now    func() time.Time

	mu    sync.Mutex
	plans map[string]*Plan
	jobs  []*Job
	busy  bool
}

func newPlanner(inv *Inventory, run Runner, cfg Config, log *slog.Logger) *Planner {
	return &Planner{inv: inv, run: run, online: newCreator(run, cfg), log: log, now: time.Now, plans: map[string]*Plan{}}
}

// Plan makes a plan and keeps it for apply.
func (pl *Planner) Plan(ctx context.Context, in Intent) (*Plan, error) {
	v, err := pl.inv.view(ctx)
	if err != nil {
		return nil, err
	}
	p, err := pl.make(v, in)
	if err != nil {
		return nil, err
	}
	id := make([]byte, 12)
	_, _ = rand.Read(id)
	p.ID, p.Intent, p.Expires = hex.EncodeToString(id), in, pl.now().Add(planTTL)
	for _, s := range p.steps {
		p.Steps = append(p.Steps, s.text)
		if s.argv != nil {
			p.Commands = append(p.Commands, s.argv)
		}
	}
	if p.Effects.Erases == nil {
		p.Effects.Erases = []string{}
	}
	if p.Effects.Notes == nil {
		p.Effects.Notes = []string{}
	}
	pl.mu.Lock()
	for id, old := range pl.plans {
		if pl.now().After(old.Expires) {
			delete(pl.plans, id)
		}
	}
	pl.plans[p.ID] = p
	pl.mu.Unlock()
	return p, nil
}

// Apply runs a plan made before, if the machine still gives the same plan and the confirmation
// matches. The steps run in the background as a Job.
func (pl *Planner) Apply(ctx context.Context, id, confirm string) (*Job, error) {
	pl.mu.Lock()
	p := pl.plans[id]
	if p == nil || pl.now().After(p.Expires) {
		pl.mu.Unlock()
		return nil, errNoPlan
	}
	busy := pl.busy
	pl.mu.Unlock()
	if busy {
		return nil, errBusy
	}
	if p.Confirm != "" && strings.TrimSpace(confirm) != p.Confirm {
		return nil, errConfirm
	}
	v, err := pl.inv.view(ctx)
	if err != nil {
		return nil, err
	}
	fresh, err := pl.make(v, p.Intent)
	if err != nil {
		return nil, err
	}
	if !sameCommands(fresh.steps, p.steps) {
		return nil, errStalePlan
	}

	pl.mu.Lock()
	if pl.busy {
		pl.mu.Unlock()
		return nil, errBusy
	}
	delete(pl.plans, id)
	pl.busy = true
	job := &Job{ID: p.ID, Verb: p.Intent.Verb, Summary: p.Summary, State: "running", Steps: len(fresh.steps), Started: pl.now()}
	pl.jobs = append(pl.jobs, job)
	if len(pl.jobs) > 20 {
		pl.jobs = pl.jobs[len(pl.jobs)-20:]
	}
	pl.mu.Unlock()

	go pl.execute(job, fresh.steps)
	return job.snapshot(&pl.mu), nil
}

func sameCommands(a, b []step) bool {
	return slices.EqualFunc(a, b, func(x, y step) bool { return x.text == y.text && slices.Equal(x.argv, y.argv) })
}

func (j *Job) snapshot(mu *sync.Mutex) *Job {
	mu.Lock()
	defer mu.Unlock()
	c := *j
	return &c
}

// execute runs the steps in order, stopping at the first that fails.
func (pl *Planner) execute(job *Job, steps []step) {
	ctx := context.Background()
	var failure error
	for i, s := range steps {
		if s.argv != nil {
			if _, err := pl.run.Run(ctx, s.argv[0], s.argv[1:]...); err != nil {
				failure = fmt.Errorf("%s: %w", s.text, err)
			}
		}
		if failure == nil && s.wait != nil {
			if err := s.wait(ctx); err != nil {
				failure = fmt.Errorf("%s: %w", s.text, err)
			}
		}
		if failure != nil {
			break
		}
		pl.mu.Lock()
		job.Step = i + 1
		pl.mu.Unlock()
	}
	end := pl.now()
	pl.mu.Lock()
	defer pl.mu.Unlock()
	job.Ended, pl.busy = &end, false
	if failure != nil {
		job.State, job.Error = "failed", failure.Error()
		pl.log.Error("storage job failed", "verb", job.Verb, "error", failure)
		return
	}
	job.State = "done"
	pl.log.Info("storage job done", "verb", job.Verb, "summary", job.Summary)
}

// Jobs is the recent jobs, newest last.
func (pl *Planner) Jobs() []Job {
	pl.mu.Lock()
	defer pl.mu.Unlock()
	jobs := make([]Job, 0, len(pl.jobs))
	for _, j := range pl.jobs {
		jobs = append(jobs, *j)
	}
	return jobs
}

// Busy reports whether a job runs.
func (pl *Planner) Busy() bool {
	pl.mu.Lock()
	defer pl.mu.Unlock()
	return pl.busy
}

// make is the plan for an intent on view v, or a refusal saying why there is none.
func (pl *Planner) make(v *storageView, in Intent) (*Plan, error) {
	pool := v.pool
	if in.Verb != "create-pool" && in.Verb != "wipe-disk" && pool == nil {
		return nil, refuse("there is no pool yet")
	}
	if pool != nil {
		switch in.Verb {
		case "create-pool", "wipe-disk":
		case "mount-degraded":
			if pool.Mounted {
				return nil, refuse("the pool is mounted")
			}
		case "cancel-check":
			if pool.Action != "check" && pool.State != "checking" {
				return nil, refuse("no check is running")
			}
		default:
			if !pool.Mounted {
				return nil, refuse("the pool is not mounted: mount it with the disk missing first")
			}
			if !pool.idle() {
				return nil, refuse("the pool is busy (%s): wait until that is done", pool.State)
			}
		}
	}
	switch in.Verb {
	case "create-pool":
		return pl.createPool(v, in)
	case "add-disk":
		return pl.addDisk(v, in)
	case "replace-disk":
		return pl.replaceDisk(v, in)
	case "remove-disk":
		return pl.removeDisk(v, in)
	case "change-layout":
		return pl.changeLayout(v, in)
	case "restore-layout":
		return pl.restoreLayout(v)
	case "check":
		if pool.Backend == "md" {
			return &Plan{Summary: "Check every block of the pool", Effects: pool.same(true), steps: []step{{text: "Start a check of the array", argv: []string{"mdadm", "--action=check", pool.device}}}}, nil
		}
		return &Plan{Summary: "Check every block of the pool", Effects: pool.same(true), steps: []step{{text: "Start a scrub", argv: []string{"btrfs", "scrub", "start", pool.mount}}}}, nil
	case "cancel-check":
		if pool.Backend == "md" {
			return &Plan{Summary: "Stop the check", Effects: pool.same(false), steps: []step{{text: "Stop the check", argv: []string{"mdadm", "--action=idle", pool.device}}}}, nil
		}
		return &Plan{Summary: "Stop the check", Effects: pool.same(false), steps: []step{{text: "Cancel the scrub", argv: []string{"btrfs", "scrub", "cancel", pool.mount}}}}, nil
	case "mount-degraded":
		return pl.mountDegraded(v)
	case "wipe-disk":
		return pl.wipeDisk(v, in)
	}
	return nil, refuse("unknown action %q", in.Verb)
}

// same is effects that change neither capacity nor protection.
func (p *Pool) same(background bool) Effects {
	capacity := p.Size
	return Effects{CapacityBefore: capacity, CapacityAfter: capacity, ToleratesBefore: p.Tolerates, ToleratesAfter: p.Tolerates, Background: background}
}

// drives resolves the drive names of a request against the fresh view, each with the role the verb
// needs. Duplicates and unknown names are refused.
func drivesNamed(v *storageView, names []string, role string) ([]StorageDrive, error) {
	if len(names) == 0 {
		return nil, refuse("no disk chosen")
	}
	var out []StorageDrive
	for _, name := range names {
		d := v.drive(name)
		if d == nil {
			return nil, refuse("%s is not a disk of this machine", name)
		}
		if d.Role != role {
			return nil, refuse("%s cannot be used: it is %s", name, roleWords(d.Role))
		}
		if !strings.HasPrefix(d.Path, "/dev/") { // mdadm takes no "--": a path must not look like an option
			return nil, refuse("%s has no device path", name)
		}
		if slices.ContainsFunc(out, func(o StorageDrive) bool { return o.Name == name }) {
			return nil, refuse("%s is chosen twice", name)
		}
		out = append(out, *d)
	}
	return out, nil
}

func roleWords(role string) string {
	switch role {
	case "system":
		return "the system disk"
	case "member":
		return "already in the pool"
	case "busy":
		return "in use"
	case "foreign":
		return "not blank (wipe it first)"
	case "small":
		return "too small"
	}
	return role
}

func paths(ds []StorageDrive) []string {
	var p []string
	for _, d := range ds {
		p = append(p, d.Path)
	}
	return p
}

func driveNames(ds []StorageDrive) []string {
	var n []string
	for _, d := range ds {
		n = append(n, d.Name)
	}
	return n
}

func sizes(ds []StorageDrive) []uint64 {
	var s []uint64
	for _, d := range ds {
		s = append(s, d.Size)
	}
	return s
}

// onlineSteps bring a new or degraded-mounted pool into use: the documented manual sequence
// (Creator.bringOnline), as steps.
func (pl *Planner) onlineSteps() []step {
	cfg := pl.inv.cfg
	dataDir := path.Join(cfg.PoolMountPoint, path.Base(cfg.DataRoot))
	return []step{
		{text: "Wait for the new filesystem to appear", argv: []string{"udevadm", "settle", "--timeout=30"}},
		{text: "Mount the pool", argv: []string{"mkdir", "-p", "--", dataDir}},
		{text: "Check the pool is mounted", argv: []string{"mountpoint", "-q", "--", cfg.PoolMountPoint}},
		{text: "Bring /DATA and Docker up on it", argv: []string{"systemctl", "start", "--", "DATA.mount", "docker.service"}},
		{text: "Restart the services that use /DATA", argv: []string{"systemctl", "restart", "--", "casaos.service", "casaos-app-management.service"}},
	}
}

func (pl *Planner) createPool(v *storageView, in Intent) (*Plan, error) {
	cfg := pl.inv.cfg
	if v.pool != nil {
		return nil, refuse("there is a pool already: add disks to it instead")
	}
	if in.Layout == nil || !in.Layout.valid() {
		return nil, refuse("choose a layout")
	}
	l := *in.Layout
	ds, err := drivesNamed(v, in.Disks, "free")
	if err != nil {
		return nil, err
	}
	if len(ds) < l.MinDisks() {
		return nil, refuse("%s needs at least %s", l.String(), diskCount(l.MinDisks()))
	}
	p := &Plan{
		Summary: fmt.Sprintf("Create the pool on %s: %s", strings.Join(driveNames(ds), ", "), l.String()),
		Effects: Effects{CapacityAfter: l.Capacity(sizes(ds)), ToleratesAfter: l.Tolerates(), Erases: driveNames(ds)},
		Confirm: strings.Join(driveNames(ds), " "),
	}
	if l.Backend() == "md" {
		md := "/dev/md/" + cfg.PoolLabel
		level := map[int]string{1: "5", 2: "6"}[l.Parity]
		p.steps = append(p.steps,
			step{text: "Create the RAID " + level + " array", argv: append([]string{"mdadm", "--create", md, "--name=" + cfg.PoolLabel, "--run", "--level=" + level,
				"--raid-devices=" + strconv.Itoa(len(ds)), "--metadata=1.2"}, paths(ds)...)},
			step{text: "Wait for the array", argv: []string{"udevadm", "settle", "--timeout=30"}},
			step{text: "Make the filesystem on the array", argv: []string{"mkfs.btrfs", "-f", "-L", cfg.PoolLabel, "-d", "single", "-m", "dup", "--", md}},
		)
		p.Effects.Background = true
		p.Effects.Notes = append(p.Effects.Notes, "The array builds its parity in the background; the pool is usable meanwhile.")
	} else {
		p.steps = append(p.steps, step{text: "Make the filesystem", argv: append([]string{"mkfs.btrfs", "-f", "-L", cfg.PoolLabel,
			"-d", l.Profile(), "-m", l.metadataProfile(len(ds)), "--"}, paths(ds)...)})
	}
	p.steps = append(p.steps, pl.onlineSteps()...)
	return p, nil
}

func (pl *Planner) addDisk(v *storageView, in Intent) (*Plan, error) {
	pool := v.pool
	ds, err := drivesNamed(v, in.Disks, "free")
	if err != nil {
		return nil, err
	}
	var memberSizes []uint64
	for _, m := range pool.present() {
		memberSizes = append(memberSizes, m.Size)
	}
	after := append(slices.Clone(memberSizes), sizes(ds)...)
	p := &Plan{
		Summary: fmt.Sprintf("Add %s to the pool", strings.Join(driveNames(ds), ", ")),
		Effects: Effects{CapacityBefore: pool.Size, ToleratesBefore: pool.Tolerates, ToleratesAfter: pool.Tolerates, Erases: driveNames(ds)},
		Confirm: strings.Join(driveNames(ds), " "),
	}
	if pool.LayoutKnown {
		p.Effects.CapacityAfter = pool.Layout.Capacity(after)
	}
	if pool.Backend == "md" {
		if len(ds) != 1 {
			return nil, refuse("add one disk at a time to a parity pool")
		}
		if uint64(pool.array.ComponentSize) > ds[0].Size {
			return nil, refuse("%s is smaller than the pool's disks", ds[0].Name)
		}
		raidDevices := strconv.Itoa(pool.Disks + 1)
		p.steps = []step{
			{text: "Add " + ds[0].Name + " to the array", argv: []string{"mdadm", "--add", pool.device, ds[0].Path}},
			{text: "Spread the array over " + raidDevices + " disks", argv: []string{"mdadm", "--grow", pool.device, "--raid-devices=" + raidDevices},
				wait: pl.mdIdle(pool.device)},
			{text: "Grow the filesystem to the new size", argv: []string{"btrfs", "filesystem", "resize", "max", pool.mount}},
		}
		p.Effects.Background = true
		p.Effects.Notes = append(p.Effects.Notes, "Spreading the data takes hours on large disks; the pool stays usable, the new space comes at the end.")
		return p, nil
	}
	p.steps = []step{{text: "Add " + strings.Join(driveNames(ds), ", ") + " to the pool", argv: append(append([]string{"btrfs", "device", "add", "-f", "--"}, paths(ds)...), pool.mount)}}
	if pool.LayoutKnown && pool.Layout.Kind == "mirror" {
		p.Effects.Notes = append(p.Effects.Notes, "New data uses every disk; data already there stays where it is.")
	}
	return p, nil
}

// member resolves a pool member by name.
func (p *Pool) member(name string) (*PoolMember, error) {
	for i := range p.Members {
		if p.Members[i].Name == name {
			return &p.Members[i], nil
		}
	}
	return nil, refuse("%s is not a disk of the pool", name)
}

func (pl *Planner) replaceDisk(v *storageView, in Intent) (*Plan, error) {
	pool := v.pool
	ds, err := drivesNamed(v, in.Disks, "free")
	if err != nil {
		return nil, err
	}
	if len(ds) != 1 {
		return nil, refuse("choose one disk to put in")
	}
	newDisk := ds[0]
	p := &Plan{
		Effects: Effects{CapacityBefore: pool.Size, CapacityAfter: pool.Size, ToleratesBefore: pool.Tolerates, Erases: []string{newDisk.Name}, Background: true},
		Confirm: newDisk.Name,
	}
	if pool.LayoutKnown {
		p.Effects.ToleratesAfter = pool.Layout.Tolerates() // whole again once rebuilt
	}

	if pool.Backend == "md" {
		if uint64(pool.array.ComponentSize) > newDisk.Size {
			return nil, refuse("%s is smaller than the pool's disks", newDisk.Name)
		}
		if in.Member == "" { // a disk is missing: the new one takes its place
			if pool.Missing == 0 {
				return nil, refuse("choose the disk to replace")
			}
			p.Summary = "Put " + newDisk.Name + " in place of the missing disk"
			p.steps = []step{{text: "Add " + newDisk.Name + "; the array rebuilds onto it", argv: []string{"mdadm", "--add", pool.device, newDisk.Path}}}
			return p, nil
		}
		old, err := pool.member(in.Member)
		if err != nil {
			return nil, err
		}
		oldPath := "/dev/" + old.Name
		p.Summary = "Replace " + old.Name + " with " + newDisk.Name
		if old.State == "faulty" {
			p.steps = []step{
				{text: "Take the failed " + old.Name + " out", argv: []string{"mdadm", pool.device, "--fail", oldPath, "--remove", oldPath}},
				{text: "Add " + newDisk.Name + "; the array rebuilds onto it", argv: []string{"mdadm", "--add", pool.device, newDisk.Path}},
			}
			return p, nil
		}
		p.steps = []step{
			{text: "Add " + newDisk.Name + " as a spare", argv: []string{"mdadm", "--add", pool.device, newDisk.Path}},
			{text: "Copy " + old.Name + " onto " + newDisk.Name + ", then take " + old.Name + " out", argv: []string{"mdadm", "--replace", pool.device, oldPath, "--with", newDisk.Path}},
		}
		p.Effects.ToleratesAfter = pool.Tolerates
		p.Effects.Notes = append(p.Effects.Notes, "The pool keeps its protection during the copy.")
		return p, nil
	}

	if in.Member == "" {
		return nil, refuse("choose the disk to replace")
	}
	old, err := pool.member(in.Member)
	if err != nil {
		return nil, err
	}
	if old.Size > newDisk.Size {
		return nil, refuse("%s is smaller than %s", newDisk.Name, old.Name)
	}
	p.Summary = "Replace " + old.Name + " with " + newDisk.Name
	p.steps = []step{{text: "Copy " + old.Name + "'s data onto " + newDisk.Name + " (from the other disks if it is gone)",
		argv: []string{"btrfs", "replace", "start", "-f", strconv.FormatUint(old.devid, 10), newDisk.Path, pool.mount},
		wait: pl.btrfsIdle(pool)}}
	if old.State != "active" && pool.LayoutKnown {
		// what was written while the disk was gone has one copy: back into the layout, the rest is untouched
		p.steps = append(p.steps, pl.softConvert(pool, "Give the data written meanwhile its copies again"))
	}
	if old.State == "active" {
		p.Effects.ToleratesAfter = pool.Tolerates
	}
	if newDisk.Size > old.Size {
		p.Effects.Notes = append(p.Effects.Notes, newDisk.Name+" is larger: the extra space is used after the next layout change.")
	}
	return p, nil
}

func (pl *Planner) removeDisk(v *storageView, in Intent) (*Plan, error) {
	pool := v.pool
	old, err := pool.member(in.Member)
	if err != nil {
		return nil, err
	}
	p := &Plan{Confirm: old.Name, Effects: Effects{CapacityBefore: pool.Size, ToleratesBefore: pool.Tolerates, ToleratesAfter: pool.Tolerates}}
	if pool.Backend == "md" {
		if old.State != "faulty" && old.State != "spare" {
			return nil, refuse("only a failed or spare disk can be taken out of a parity pool: replace %s instead", old.Name)
		}
		oldPath := "/dev/" + old.Name
		p.Summary = "Take " + old.Name + " out of the pool"
		p.Effects.CapacityAfter = pool.Size
		p.steps = []step{
			{text: "Take " + old.Name + " out of the array", argv: []string{"mdadm", pool.device, "--fail", oldPath, "--remove", oldPath}},
			{text: "Clear the array's mark on " + old.Name, argv: []string{"mdadm", "--zero-superblock", oldPath}},
		}
		return p, nil
	}
	var rest []uint64
	for _, m := range pool.present() {
		if m.Name != old.Name {
			rest = append(rest, m.Size)
		}
	}
	if pool.LayoutKnown && len(rest) < pool.Layout.MinDisks() {
		return nil, refuse("%s needs at least %s: replace %s instead, or change the layout first", pool.Layout.String(), diskCount(pool.Layout.MinDisks()), old.Name)
	}
	p.Summary = "Take " + old.Name + " out of the pool"
	p.Effects.CapacityAfter = pool.Layout.Capacity(rest)
	target := strconv.FormatUint(old.devid, 10)
	if old.Disk == "" {
		target = "missing"
	}
	p.steps = []step{{text: "Move " + old.Name + "'s data to the other disks and take it out", argv: []string{"btrfs", "device", "remove", target, pool.mount}}}
	if pool.Used > p.Effects.CapacityAfter && p.Effects.CapacityAfter > 0 {
		return nil, refuse("the data (%s) does not fit on the other disks (%s)", formatBytes(pool.Used), formatBytes(p.Effects.CapacityAfter))
	}
	p.Effects.Notes = append(p.Effects.Notes, "Takes as long as moving "+old.Name+"'s data; the pool stays usable.")
	return p, nil
}

func (pl *Planner) changeLayout(v *storageView, in Intent) (*Plan, error) {
	pool := v.pool
	if in.Layout == nil || !in.Layout.valid() {
		return nil, refuse("choose a layout")
	}
	l := *in.Layout
	if !slices.Contains(pool.layoutTargets(), l) {
		if l.Backend() != "btrfs" {
			return nil, refuse("%s needs a new pool: it cannot be converted to", l.String())
		}
		return nil, refuse("%s is not possible with %s", l.String(), diskCount(len(pool.present())))
	}
	var present []uint64
	for _, m := range pool.present() {
		present = append(present, m.Size)
	}
	p := &Plan{
		Summary: "Change the layout to " + l.String(),
		Effects: Effects{CapacityBefore: pool.Size, CapacityAfter: l.Capacity(present), ToleratesBefore: pool.Tolerates, ToleratesAfter: l.Tolerates(), Background: true},
		steps: []step{{text: "Rewrite every block in the new layout", argv: []string{"btrfs", "balance", "start", "--bg", "-f",
			"-dconvert=" + l.Profile(), "-mconvert=" + l.metadataProfile(len(present)), pool.mount}}},
	}
	if pool.Used > p.Effects.CapacityAfter {
		return nil, refuse("the data (%s) does not fit in the new layout (%s)", formatBytes(pool.Used), formatBytes(p.Effects.CapacityAfter))
	}
	if l.Tolerates() < pool.Tolerates {
		p.Confirm = pool.Name // less protection: typed
		p.Effects.Notes = append(p.Effects.Notes, "The pool will survive fewer failing disks.")
	}
	p.Effects.Notes = append(p.Effects.Notes, "Rewrites all data; the pool stays usable, slower meanwhile.")
	return p, nil
}

// softConvert rewrites only the data not in the pool's layout ("soft": what is in it stays).
func (pl *Planner) softConvert(pool *Pool, text string) step {
	n := len(pool.present())
	return step{text: text, argv: []string{"btrfs", "balance", "start", "--bg",
		"-dconvert=" + pool.Layout.Profile() + ",soft", "-mconvert=" + pool.Layout.metadataProfile(n) + ",soft", pool.mount}}
}

func (pl *Planner) restoreLayout(v *storageView) (*Plan, error) {
	pool := v.pool
	if !pool.LayoutKnown {
		return nil, refuse("the pool's layout is not known")
	}
	return &Plan{
		Summary: "Restore the protection: " + pool.Layout.String(),
		Effects: Effects{CapacityBefore: pool.Size, CapacityAfter: pool.Size, ToleratesBefore: pool.Tolerates, ToleratesAfter: max(0, pool.Layout.Tolerates()-pool.Missing), Background: true,
			Notes: []string{"Rewrites only the data not in the layout; the pool stays usable."}},
		steps: []step{pl.softConvert(pool, "Rewrite the data not in the layout")},
	}, nil
}

// btrfsIdle waits until the pool's btrfs runs no exclusive operation (a replace, a balance) any more.
func (pl *Planner) btrfsIdle(pool *Pool) func(ctx context.Context) error {
	uuid := ""
	if pool.array != nil {
		uuid = pool.array.uuid
	}
	return func(ctx context.Context) error {
		for {
			select {
			case <-ctx.Done():
				return ctx.Err()
			case <-time.After(5 * time.Second):
			}
			if op := readSys(filepath.Join(pl.inv.sys, "fs", "btrfs", uuid), "exclusive_operation"); op == "none" || op == "" {
				return nil
			}
		}
	}
}

// automountUnit is the systemd automount unit of a mount point (systemd-escape --path).
func automountUnit(mountPoint string) string {
	trimmed := strings.Trim(mountPoint, "/")
	var b strings.Builder
	for i := 0; i < len(trimmed); i++ {
		c := trimmed[i]
		switch {
		case c == '/':
			b.WriteByte('-')
		case c >= 'a' && c <= 'z', c >= 'A' && c <= 'Z', c >= '0' && c <= '9', c == '_', c == '.' && i > 0:
			b.WriteByte(c)
		default:
			fmt.Fprintf(&b, `\x%02x`, c)
		}
	}
	return b.String() + ".automount"
}

func (pl *Planner) mountDegraded(v *storageView) (*Plan, error) {
	cfg := pl.inv.cfg
	pool := v.pool
	p := &Plan{
		Confirm: pool.Name,
		Effects: Effects{ToleratesBefore: 0, ToleratesAfter: 0},
	}
	p.Effects.Notes = append(p.Effects.Notes, "Until the next restart only. Replace the missing disk next: the pool has no protection meanwhile.")
	if pool.Backend == "md" {
		p.Summary = "Start the pool with a disk missing"
		p.steps = append([]step{{text: "Start the array without its missing disk", argv: []string{"mdadm", "--run", pool.device}}}, pl.onlineSteps()...)
		return p, nil
	}
	var member string
	for _, m := range pool.Members {
		if m.State == "active" && m.Disk != "" {
			member = "/dev/" + m.Name
			break
		}
	}
	if member == "" {
		return nil, refuse("no disk of the pool is present")
	}
	p.Summary = "Mount the pool with a disk missing"
	p.steps = append([]step{
		{text: "Stop mounting the pool on demand", argv: []string{"systemctl", "stop", "--", automountUnit(cfg.PoolMountPoint)}},
		{text: "Mount it with the disk missing", argv: []string{"mount", "-t", "btrfs", "-o", "degraded,noatime,compress=zstd", "--", member, cfg.PoolMountPoint}},
	}, pl.onlineSteps()[1:]...)
	return p, nil
}

func (pl *Planner) wipeDisk(v *storageView, in Intent) (*Plan, error) {
	ds, err := drivesNamed(v, in.Disks, "foreign")
	if err != nil {
		return nil, err
	}
	if len(ds) != 1 {
		return nil, refuse("wipe one disk at a time")
	}
	d := ds[0]
	p := &Plan{Summary: "Wipe " + d.Name, Confirm: d.Name, Effects: Effects{Erases: []string{d.Name}}}
	var members []Block
	walk(d.block, func(b Block) {
		if b.Path != d.Path && b.Type == "part" {
			members = append(members, b)
		}
	})
	for _, b := range append(members, d.block) {
		if b.FSType == "linux_raid_member" {
			p.steps = append(p.steps, step{text: "Clear the RAID mark on " + b.Name, argv: []string{"mdadm", "--zero-superblock", b.Path}})
		}
	}
	for _, b := range members {
		p.steps = append(p.steps, step{text: "Erase the signatures on " + b.Name, argv: []string{"wipefs", "-a", "--", b.Path}})
	}
	p.steps = append(p.steps,
		step{text: "Erase the signatures and partition table on " + d.Name, argv: []string{"wipefs", "-a", "--", d.Path}},
		step{text: "Let the system see the blank disk", argv: []string{"udevadm", "settle", "--timeout=30"}},
	)
	return p, nil
}

// mdIdle waits until the md array's sync_action is idle again (a reshape done).
func (pl *Planner) mdIdle(device string) func(ctx context.Context) error {
	return func(ctx context.Context) error {
		name := filepath.Base(device)
		if real, err := filepath.EvalSymlinks(device); err == nil {
			name = filepath.Base(real)
		}
		for {
			select {
			case <-ctx.Done():
				return ctx.Err()
			case <-time.After(5 * time.Second):
			}
			if readSys(filepath.Join(pl.inv.sys, "block", name, "md"), "sync_action") == "idle" {
				return nil
			}
		}
	}
}
