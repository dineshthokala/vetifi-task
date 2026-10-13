/// A sleek, modern glassmorphic badge for displaying dataset formulary version.
library;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class VersionBadge extends StatelessWidget {
  final String version;
  final VoidCallback? onTap;

  const VersionBadge({
    super.key,
    required this.version,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    if (version.isEmpty) return const SizedBox.shrink();

    final formatted = version.toLowerCase().startsWith('v')
        ? version
        : 'v$version';

    return Center(
      child: Tooltip(
        message: 'Formulary Dataset $formatted',
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(20),
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 6),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4.5),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.22),
                  width: 1,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Container(
                    width: 6,
                    height: 6,
                    decoration: const BoxDecoration(
                      color: Color(0xFF38BDF8), // Radiant cyan status dot
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 5.5),
                  Text(
                    formatted,
                    style: GoogleFonts.plusJakartaSans(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: Colors.white.withValues(alpha: 0.95),
                      letterSpacing: 0.3,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
