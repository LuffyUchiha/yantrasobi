/// Declarative Curve Kick scenarios. Units are metres on a 40 x 60 half pitch;
/// the goal is centred on y = 0 (top), play goes upward (decreasing y).
library;

class Patrol {
  const Patrol(this.dx, this.dy, this.period);
  final double dx;
  final double dy;
  final double period;
}

class DefenderDef {
  const DefenderDef(this.x, this.y, {this.patrol});
  final double x;
  final double y;
  final Patrol? patrol;
}

class KickLevel {
  const KickLevel({
    required this.name,
    required this.holder,
    this.mates = const [],
    this.defenders = const [],
    this.keeperSpeed = 4.0,
    this.attempts = 3,
  });
  final String name;
  final (double, double) holder;
  final List<(double, double)> mates;
  final List<DefenderDef> defenders;
  final double keeperSpeed;
  final int attempts;
}

const double kPitchWidth = 40;
const double kPitchLength = 60;
const double kGoalWidth = 7.3;

const List<KickLevel> kKickLevels = [
  KickLevel(name: 'Open Goal Nerves', holder: (20, 22), keeperSpeed: 1.2),
  KickLevel(name: 'Beat the Wall', holder: (20, 26), defenders: [DefenderDef(18, 18), DefenderDef(22, 18)]),
  KickLevel(name: 'Square It', holder: (8, 20), mates: [(28, 16)], defenders: [DefenderDef(14, 14)]),
  KickLevel(
    name: 'Around the Corner',
    holder: (34, 24),
    defenders: [DefenderDef(28, 16), DefenderDef(22, 12), DefenderDef(15, 16)],
  ),
  KickLevel(
    name: 'One-Two',
    holder: (12, 34),
    mates: [(26, 22)],
    defenders: [
      DefenderDef(18, 26, patrol: Patrol(4, 0, 3)),
      DefenderDef(22, 14),
    ],
  ),
  KickLevel(
    name: 'Through Ball',
    holder: (20, 44),
    mates: [(30, 18)],
    defenders: [
      DefenderDef(20, 32),
      DefenderDef(26, 26, patrol: Patrol(0, 3, 2.5)),
      DefenderDef(14, 22),
    ],
    keeperSpeed: 4.5,
  ),
  KickLevel(
    name: 'Crowded Box',
    holder: (30, 30),
    mates: [(10, 20)],
    defenders: [
      DefenderDef(20, 22),
      DefenderDef(24, 14, patrol: Patrol(-4, 0, 2.8)),
      DefenderDef(14, 12),
      DefenderDef(28, 20),
    ],
    keeperSpeed: 5,
  ),
  KickLevel(
    name: 'Switch Play',
    holder: (6, 40),
    mates: [(34, 34), (26, 16)],
    defenders: [
      DefenderDef(20, 36, patrol: Patrol(0, 4, 2.2)),
      DefenderDef(30, 24),
      DefenderDef(18, 18, patrol: Patrol(5, 0, 3)),
      DefenderDef(22, 10),
    ],
    keeperSpeed: 5,
  ),
  KickLevel(
    name: 'Long Range',
    holder: (20, 40),
    defenders: [
      DefenderDef(16, 30, patrol: Patrol(8, 0, 2.6)),
      DefenderDef(24, 22, patrol: Patrol(-8, 0, 2.4)),
      DefenderDef(20, 12),
    ],
    keeperSpeed: 5.5,
  ),
  KickLevel(
    name: 'Final Whistle',
    holder: (10, 46),
    mates: [(30, 36), (14, 20)],
    defenders: [
      DefenderDef(20, 40, patrol: Patrol(0, 3, 2)),
      DefenderDef(24, 28, patrol: Patrol(-6, 0, 2.6)),
      DefenderDef(10, 28),
      DefenderDef(20, 16, patrol: Patrol(6, 0, 2.2)),
      DefenderDef(26, 10),
    ],
    keeperSpeed: 6,
  ),
];
