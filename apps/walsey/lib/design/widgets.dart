import 'package:flutter/material.dart';

import 'tokens.dart';

/// Tone for status badges and banners. Every badge renders a label as well as
/// a color: the design never relies on color alone.
enum WBadgeTone { online, connecting, offline, error, planned, unsupported }

extension on WBadgeTone {
  Color get background => switch (this) {
    WBadgeTone.online => WalseyColors.successBg,
    WBadgeTone.connecting => WalseyColors.warningBg,
    WBadgeTone.offline => WalseyColors.offlineBg,
    WBadgeTone.error => WalseyColors.errorBg,
    WBadgeTone.planned => WalseyColors.primaryTint,
    WBadgeTone.unsupported => WalseyColors.errorBg,
  };

  Color get foreground => switch (this) {
    WBadgeTone.online => WalseyColors.successText,
    WBadgeTone.connecting => WalseyColors.warningText,
    WBadgeTone.offline => WalseyColors.offlineText,
    WBadgeTone.error => WalseyColors.errorText,
    WBadgeTone.planned => WalseyColors.primaryText,
    WBadgeTone.unsupported => WalseyColors.errorText,
  };
}

class WBadge extends StatelessWidget {
  const WBadge({super.key, required this.label, required this.tone});

  final String label;
  final WBadgeTone tone;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    decoration: BoxDecoration(
      color: tone.background,
      borderRadius: BorderRadius.circular(WalseyRadius.badge),
    ),
    child: Text(
      label,
      style: WalseyType.badge.copyWith(color: tone.foreground),
    ),
  );
}

/// Surface card. `label` renders the design's uppercase section label.
class WCard extends StatelessWidget {
  const WCard({
    super.key,
    this.label,
    this.trailing,
    this.padding = const EdgeInsets.all(WalseySpacing.xxl),
    this.child,
  });

  final String? label;
  final Widget? trailing;
  final EdgeInsetsGeometry padding;
  final Widget? child;

  @override
  Widget build(BuildContext context) => Container(
    padding: padding,
    decoration: BoxDecoration(
      color: WalseyColors.surface,
      borderRadius: BorderRadius.circular(WalseyRadius.card),
      border: Border.all(color: WalseyColors.border),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (label != null)
          Padding(
            padding: const EdgeInsets.only(bottom: WalseySpacing.md),
            child: Row(
              children: [
                Expanded(child: WSectionLabel(label!)),
                ?trailing,
              ],
            ),
          )
        else if (trailing != null)
          Padding(
            padding: const EdgeInsets.only(bottom: WalseySpacing.md),
            child: Align(alignment: Alignment.centerRight, child: trailing),
          ),
        ?child,
      ],
    ),
  );
}

class WSectionLabel extends StatelessWidget {
  const WSectionLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text.toUpperCase(),
    style: WalseyType.sectionLabel,
  );
}

class WPageHeader extends StatelessWidget {
  const WPageHeader({
    super.key,
    required this.title,
    this.caption,
    this.actions = const <Widget>[],
    this.compact = false,
  });

  final String title;
  final String? caption;
  final List<Widget> actions;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final heading = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          title,
          style: compact ? WalseyType.pageTitleMobile : WalseyType.pageTitle,
        ),
        if (caption != null) ...[
          const SizedBox(height: 2),
          Text(caption!, style: WalseyType.caption),
        ],
      ],
    );

    if (actions.isEmpty) return heading;
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 560) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              heading,
              const SizedBox(height: WalseySpacing.lg),
              Wrap(spacing: WalseySpacing.sm, runSpacing: WalseySpacing.sm, children: actions),
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(child: heading),
            Wrap(spacing: WalseySpacing.sm, runSpacing: WalseySpacing.sm, children: actions),
          ],
        );
      },
    );
  }
}

/// Scrollable page body: design padding (24x28 desktop, 16 mobile) and a
/// maximum content width so very wide Windows windows stay readable.
class WPageBody extends StatelessWidget {
  const WPageBody({
    super.key,
    required this.children,
    this.compact = false,
    this.maxWidth = WalseySpacing.maxContentWidth,
    this.padding,
  });

  final List<Widget> children;
  final bool compact;
  final double maxWidth;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    padding: padding ??
        (compact
            ? const EdgeInsets.fromLTRB(
                WalseySpacing.screenMobile,
                WalseySpacing.screenMobile,
                WalseySpacing.screenMobile,
                WalseySpacing.sm,
              )
            : const EdgeInsets.symmetric(
                horizontal: WalseySpacing.screenDesktopX,
                vertical: WalseySpacing.screenDesktopY,
              )),
    child: Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var index = 0; index < children.length; index++) ...[
              if (index > 0) const SizedBox(height: WalseySpacing.xxl),
              children[index],
            ],
          ],
        ),
      ),
    ),
  );
}

/// Simple responsive row of cards: columns collapse on narrow widths.
class WResponsiveGrid extends StatelessWidget {
  const WResponsiveGrid({
    super.key,
    required this.children,
    this.minChildWidth = 260,
    this.spacing = WalseySpacing.xl,
  });

  final List<Widget> children;
  final double minChildWidth;
  final double spacing;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final width = constraints.maxWidth;
      final columns = ((width + spacing) / (minChildWidth + spacing))
          .floor()
          .clamp(1, children.length);
      final childWidth = (width - spacing * (columns - 1)) / columns;
      return Wrap(
        spacing: spacing,
        runSpacing: spacing,
        children: [
          for (final child in children) SizedBox(width: childWidth, child: child),
        ],
      );
    },
  );
}

class WListRow extends StatelessWidget {
  const WListRow({
    super.key,
    required this.title,
    this.caption,
    this.leading,
    this.trailing,
    this.onTap,
    this.showDivider = true,
  });

  final String title;
  final String? caption;
  final Widget? leading;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool showDivider;

  @override
  Widget build(BuildContext context) {
    final content = Padding(
      padding: const EdgeInsets.symmetric(vertical: WalseySpacing.md),
      child: Row(
        children: [
          if (leading != null) ...[leading!, const SizedBox(width: WalseySpacing.md)],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: WalseyType.rowTitle),
                if (caption != null) ...[
                  const SizedBox(height: 2),
                  Text(caption!, style: WalseyType.caption),
                ],
              ],
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: WalseySpacing.md),
            trailing!,
          ],
        ],
      ),
    );

    final tappable = onTap == null
        ? content
        : InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(WalseyRadius.control),
            child: content,
          );

    return Column(
      children: [
        tappable,
        if (showDivider) const Divider(height: 1, thickness: 1),
      ],
    );
  }
}

enum WInfoTone { info, success, warning, error }

class WInfoBanner extends StatelessWidget {
  const WInfoBanner({
    super.key,
    required this.message,
    this.title,
    this.tone = WInfoTone.info,
    this.icon,
    this.action,
  });

  final String message;
  final String? title;
  final WInfoTone tone;
  final IconData? icon;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final (background, foreground, fallbackIcon) = switch (tone) {
      WInfoTone.info => (
        WalseyColors.primaryTint,
        WalseyColors.primaryText,
        Icons.info_outline,
      ),
      WInfoTone.success => (
        WalseyColors.successBg,
        WalseyColors.successText,
        Icons.check_circle_outline,
      ),
      WInfoTone.warning => (
        WalseyColors.warningBg,
        WalseyColors.warningText,
        Icons.warning_amber_outlined,
      ),
      WInfoTone.error => (
        WalseyColors.errorBg,
        WalseyColors.errorText,
        Icons.error_outline,
      ),
    };

    return Container(
      padding: const EdgeInsets.all(WalseySpacing.lg),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(WalseyRadius.card),
        border: Border.all(color: foreground.withValues(alpha: 0.22)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon ?? fallbackIcon, size: 18, color: foreground),
          const SizedBox(width: WalseySpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (title != null) ...[
                  Text(
                    title!,
                    style: WalseyType.rowTitle.copyWith(color: foreground),
                  ),
                  const SizedBox(height: 2),
                ],
                Text(
                  message,
                  style: WalseyType.caption.copyWith(color: foreground),
                ),
              ],
            ),
          ),
          if (action != null) ...[const SizedBox(width: WalseySpacing.sm), action!],
        ],
      ),
    );
  }
}

class WEmptyState extends StatelessWidget {
  const WEmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.action,
  });

  final IconData icon;
  final String title;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(
      horizontal: WalseySpacing.huge,
      vertical: WalseySpacing.giant,
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 52,
          height: 52,
          decoration: BoxDecoration(
            color: WalseyColors.surfaceRaised,
            shape: BoxShape.circle,
            border: Border.all(color: WalseyColors.border),
          ),
          child: Icon(icon, color: WalseyColors.textSecondary),
        ),
        const SizedBox(height: WalseySpacing.lg),
        Text(title, style: WalseyType.sectionTitle, textAlign: TextAlign.center),
        const SizedBox(height: WalseySpacing.xs),
        Text(
          message,
          style: WalseyType.caption,
          textAlign: TextAlign.center,
        ),
        if (action != null) ...[
          const SizedBox(height: WalseySpacing.xxl),
          action!,
        ],
      ],
    ),
  );
}

/// Honest page for capabilities that are designed but not implemented in this
/// build. It never offers controls that pretend to work.
class WPlannedFeature extends StatelessWidget {
  const WPlannedFeature({
    super.key,
    required this.icon,
    required this.title,
    required this.summary,
    required this.requirements,
    this.note,
    this.compact = false,
  });

  final IconData icon;
  final String title;
  final String summary;
  final List<String> requirements;
  final String? note;
  final bool compact;

  @override
  Widget build(BuildContext context) => WPageBody(
    compact: compact,
    children: [
      WPageHeader(
        title: title,
        compact: compact,
        actions: const [WBadge(label: 'Planned', tone: WBadgeTone.planned)],
      ),
      WCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: WalseyColors.primaryTint,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(icon, color: WalseyColors.primaryText),
                ),
                const SizedBox(width: WalseySpacing.xl),
                Expanded(
                  child: Text(summary, style: WalseyType.body),
                ),
              ],
            ),
            const SizedBox(height: WalseySpacing.xxl),
            const WSectionLabel('What this needs'),
            const SizedBox(height: WalseySpacing.sm),
            for (final requirement in requirements)
              Padding(
                padding: const EdgeInsets.only(top: WalseySpacing.sm),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Padding(
                      padding: EdgeInsets.only(top: 2),
                      child: Icon(
                        Icons.radio_button_unchecked,
                        size: 14,
                        color: WalseyColors.textMuted,
                      ),
                    ),
                    const SizedBox(width: WalseySpacing.md),
                    Expanded(child: Text(requirement, style: WalseyType.body)),
                  ],
                ),
              ),
          ],
        ),
      ),
      if (note != null)
        WInfoBanner(
          tone: WInfoTone.info,
          title: 'Why this page exists',
          message: note!,
        ),
    ],
  );
}

/// Labelled switch row used across Settings.
class WToggleRow extends StatelessWidget {
  const WToggleRow({
    super.key,
    required this.title,
    required this.value,
    required this.onChanged,
    this.caption,
    this.enabled = true,
  });

  final String title;
  final String? caption;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: WalseySpacing.sm),
    child: Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: WalseyType.rowTitle),
              if (caption != null) ...[
                const SizedBox(height: 2),
                Text(caption!, style: WalseyType.caption),
              ],
            ],
          ),
        ),
        const SizedBox(width: WalseySpacing.md),
        Transform.scale(
          scale: 0.82,
          child: Switch(value: value, onChanged: enabled ? onChanged : null),
        ),
      ],
    ),
  );
}
