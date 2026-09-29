% Two generators with mbase (50) off the system base (100) and known gencost rows:
% a quadratic with a constant and a start-up cost, and a three-point piecewise-linear.
function mpc = cost_units
mpc.version = '2';
mpc.baseMVA = 100.0;
mpc.bus = [
	1	3	0.0	0.0	0.0	0.0	1	1.0	0.0	230.0	1	1.1	0.9;
	2	1	50.0	10.0	0.0	0.0	1	1.0	0.0	230.0	1	1.1	0.9;
];
mpc.gen = [
	1	40.0	0.0	30.0	-30.0	1.0	50.0	1	80.0	10.0	0.0	0.0	0.0	0.0	0.0	0.0	0.0	0.0	0.0	0.0	0.0;
	1	20.0	0.0	30.0	-30.0	1.0	50.0	1	60.0	0.0	0.0	0.0	0.0	0.0	0.0	0.0	0.0	0.0	0.0	0.0	0.0;
];
mpc.branch = [
	1	2	0.01	0.1	0.0	100.0	100.0	100.0	0.0	0.0	1	-30.0	30.0;
];
mpc.gencost = [
	2	1500.0	0.0	3	0.02	16.0	200.0	0.0	0.0	0.0;
	1	0.0	0.0	3	10.0	300.0	40.0	900.0	60.0	1600.0;
];
