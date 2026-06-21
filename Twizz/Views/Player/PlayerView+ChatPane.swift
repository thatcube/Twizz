import AVKit
import GameController
import Observation
import SwiftUI
import UIKit

extension PlayerView {
  var chatPane: some View {
    let isGlass = chatLayoutMode == .glass
    let useLighterOverlayBackground = chatLayoutMode == .overlay
    return VStack(spacing: 0) {
      // ChatView is wrapped so the live `chat.messages` read happens inside the
      // wrapper's body, not PlayerView's. Otherwise every incoming chat message
      // (several per second on busy channels) re-executes the whole PlayerView
      // body and flashes the focused Quality menu while it's open.
      ChatMessagesColumn(
        chat: isVOD ? nil : chat,
        replay: isVOD ? replay : nil,
        channel: channel,
        replayStartMessageID: chatReplayStartMessageID,
        frozenMessages: chatFrozenMessages,
        textSize: chatTextSize,
        emoteSize: chatEmoteSize,
        messageSpacing: chatMessageSpacing,
        lineHeight: chatLineHeight,
        letterSpacing: chatLetterSpacing,
        animatedEmotes: chatAnimatedEmotes,
        fontStyle: chatFontStyle,
        showBadges: chatShowBadges,
        showPlatformBadges: chatShowPlatformBadges,
        highlightEnabled: chatHighlightMentionsEnabled,
        viewerLogin: auth.userLogin,
        viewerDisplayName: auth.userDisplayName,
        highlightKeywords: chatHighlightKeywordList,
        useGlassBackground: isGlass,
        useLighterOverlayBackground: useLighterOverlayBackground,
        autoScroll: !(isChatScrolling || chatSoftPauseRemaining != nil),
        softPauseRemaining: chatSoftPauseRemaining,
        softPauseTotal: softPauseSeconds,
        scrollTarget: chatScrollTarget
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .overlay {
        // VOD chat is read-only: there's no composer to send from. Instead an
        // invisible focusable sits over the message list. Pressing right off the
        // collapse-chat button lands here (surfacing the paused indicator); from
        // here up/down scroll the replay and left returns to the controls.
        if isVOD {
          Color.clear
            .contentShape(Rectangle())
            .focusable(showChat && focus != .rewindScrubber)
            .focused($focus, equals: .chatScroller)
            .onMoveCommand { direction in
              switch direction {
              case .up: handleChatUpPress()
              case .down: handleChatDownPress()
              case .left:
                resumeChatLive()
                revealControls(preferredFocus: .chatToggle)
              default: break
              }
            }
        }
      }
      // Live interactive moments (polls / predictions / hype trains / goals)
      // float over the TOP of the chat list rather than pushing it down, so the
      // messages scroll behind the card (matching Twitch on the web). Only
      // visible while chat is open (this whole pane is). Passive +
      // non-interactive: never takes focus, so chat keeps scrolling underneath.
      .overlay(alignment: .top) {
        if let moment = hermes.currentMoment, !isSleeping, isEventEnabled(moment) {
          dockedInteractiveMoment(moment, style: momentDockStyle(isGlass: isGlass))
            .transition(.motionAware(.move(edge: .top).combined(with: .opacity), reduceMotion: reduceMotion))
        }
      }

      if !isVOD {
        chatComposerBar
      }
    }
    .frame(width: chatWidth)
    .modifier(GlassChatPaneStyle(enabled: isGlass))
    // Prevent the glass container from showing a focus glow when interactive
    // elements inside (e.g. the chat input) receive focus.
    .focusEffectDisabled()
    // The settings panel floats to the LEFT of the chat so the whole chat stays
    // visible while you adjust it, anchored toward the BOTTOM so it sits near the
    // settings button (now in the bottom control row) instead of way up top. It
    // is attached *outside* GlassChatPaneStyle so the glass pane's rounded clip
    // never hides it in glass layout mode.
    .overlay(alignment: .bottomLeading) {
      if showChatSettings {
        let topInset: CGFloat = isGlass ? GlassChatPaneStyle.edgeInset + 16 : 16
        GeometryReader { geo in
          chatSettingsPanel(
            maxHeight: max(geo.size.height - topInset - chatSettingsBottomClearance, 0)
          )
          .frame(width: chatSettingsPanelWidth)
          .padding(.top, topInset)
          .padding(.bottom, chatSettingsBottomClearance)
          .offset(x: -(chatSettingsPanelWidth + chatSettingsPanelGap))
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
        .frame(width: chatSettingsPanelWidth)
        .transition(.move(edge: .bottom).combined(with: .opacity))
      }
    }
    .animation(.easeOut(duration: 0.18), value: showChatSettings)
  }

  /// Distance the bottom control row sits above the screen's bottom edge. Kept
  /// generous so the row (and the chat composer it aligns with) clears typical TV
  /// overscan instead of hugging the very bottom.
  /// Bottom inset for the control cluster. Lifts the row 16pt off the very bottom
  /// edge, and in floating Glass chat mode adds the pane's edge inset so the
  /// buttons line up with the floating chat's bottom margin.
  var controlsBottomPadding: CGFloat {
    let glassLift = (chatLayoutMode == .glass && showChat) ? GlassChatPaneStyle.edgeInset : 0
    return 24 + glassLift
  }
  /// How far above the screen bottom the floating settings panel must start so it
  /// floats *above* the control row rather than behind/under it. Control row
  /// bottom inset plus its approximate height plus a small gap. When the rewind
  /// scrub bar is present it sits *below* the control row in the same VStack, so
  /// the panel has to clear that extra element too (bar height + the VStack's
  /// 18pt spacing) or it overlaps the seek bar and the buttons beneath it.
  var chatSettingsBottomClearance: CGFloat {
    let base = controlsBottomPadding + 104
    return rewindAvailable ? base + scrubBarClusterHeight : base
  }


  var hasChatDraft: Bool {
    !chatDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var chatComposerBar: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let chatSendError {
        Text(chatSendError)
          .font(.caption)
          .foregroundStyle(.orange)
          .lineLimit(2)
      }

      if let deadline = chatSyncSendDeadline, chatSyncSendDelay > 0 {
        ChatSyncSendIndicator(deadline: deadline, total: chatSyncSendDelay)
      }

      if auth.isAuthenticated {
        HStack(spacing: 16) {
          Button {
            chatInputActivationToken &+= 1
          } label: {
            Text(chatDraft.isEmpty ? "Send a message" : chatDraft)
              .font(.subheadline)
              .foregroundStyle(
                focus == .chatInput && !chatIsFrozen
                  ? .black.opacity(chatDraft.isEmpty ? 0.55 : 1.0)
                  : palette.chromeOnOpaque.opacity(chatDraft.isEmpty ? 0.5 : 1.0)
              )
              .lineLimit(1)
              .truncationMode(.tail)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.horizontal, 28)
              .frame(maxWidth: .infinity)
              .frame(height: chatComposerRowHeight)
              .modifier(ChatGlassFieldStyle(isFocused: focus == .chatInput && !chatIsFrozen))
              // The keyboard host sits *behind* the glass capsule as a full-size,
              // visually clear field. Keeping it out of the styled content (and at
              // full size) avoids a second nested background blob and stops tvOS
              // from resigning first responder on an undersized field.
              .background(
                ChatKeyboardHostField(
                  text: $chatDraft,
                  activationToken: chatInputActivationToken,
                  onSubmit: submitChatMessage
                )
                .allowsHitTesting(false)
                .accessibilityHidden(true)
              )
          }
          .buttonStyle(ChatInputButtonStyle())
          .focusEffectDisabled()
          // Mirror of the scrubber's gate: while the rewind bar is focused the
          // composer leaves the focus engine so a right-swipe/press on the bar
          // can't fling focus over here. We use `.disabled` rather than
          // `.focusable(_:)` because applying `.focusable` to a Button on tvOS
          // hijacks the Select press and stops the button's own action from
          // firing (which broke opening the keyboard). A disabled button is
          // likewise dropped from the focus engine, but only ever while the bar
          // is focused — never while the composer itself is focused — so focus
          // is never dropped.
          .disabled(chatInputFocusBlocked())
          .focused($focus, equals: .chatInput)
          .animation(.easeOut(duration: 0.18), value: focus == .chatInput && !chatIsFrozen)
          .onMoveCommand { direction in
            switch direction {
            case .left:
              exitChatComposerLeft()
            case .up:
              handleChatUpPress()
            case .down:
              handleChatDownPress()
            case .right:
              if hasChatDraft { focus = .chatSend }
            default:
              break
            }
          }

          if hasChatDraft {
            Button {
              submitChatMessage()
            } label: {
              if isSendingChat {
                ProgressView()
                  .frame(width: 24, height: 24)
              } else {
                Icon(glyph: .send, size: 24)
                  .frame(width: 24, height: 24)
              }
            }
            .TwizzControlButtonStyle(shape: .circle)
            .frame(width: chatComposerRowHeight, height: chatComposerRowHeight)
            // `.disabled` also doubles as the rewind-bar focus gate; see the
            // composer button above for why we avoid `.focusable` on a Button.
            .disabled(isSendingChat || chatInputFocusBlocked())
            .accessibilityLabel("Send message")
            .focused($focus, equals: .chatSend)
            .transition(.opacity)
            .onMoveCommand { direction in
              switch direction {
              case .left:
                focus = .chatInput
              case .up:
                focus = .chatSettingsButton
              default:
                break
              }
            }
          }
        }
        .frame(height: chatComposerRowHeight)
        .animation(.easeOut(duration: 0.18), value: hasChatDraft)
      } else {
        Button {
          showSignInSheet = true
          scheduleHide()
        } label: {
          Text("Sign in to send messages")
            .font(.subheadline)
            .foregroundStyle(
              focus == .chatInput && !chatIsFrozen
                ? .black.opacity(0.7)
                : palette.chromeOnOpaque.opacity(0.45)
            )
            .lineLimit(1)
            .padding(.horizontal, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: chatComposerRowHeight)
            .modifier(ChatGlassFieldStyle(isFocused: focus == .chatInput && !chatIsFrozen))
            .animation(.easeOut(duration: 0.18), value: focus == .chatInput && !chatIsFrozen)
        }
        .buttonStyle(ChatInputButtonStyle())
        .focusEffectDisabled()
        // Rewind-bar focus gate, expressed via `.disabled` rather than
        // `.focusable` so the Button's Select action still fires on tvOS (see
        // the signed-in composer button for the full rationale).
        .disabled(chatInputFocusBlocked())
        .focused($focus, equals: .chatInput)
        .onMoveCommand { direction in
          switch direction {
          case .left:
            exitChatComposerLeft()
          case .up:
            handleChatUpPress()
          case .down:
            handleChatDownPress()
          default:
            break
          }
        }
        .frame(height: chatComposerRowHeight)
        .accessibilityLabel("Sign in to send messages")
        .accessibilityAddTraits(.isButton)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .padding(.horizontal, 16)
    .padding(.top, 12)
    // Lift the composer off the pane's bottom edge: the base 16pt even inset plus
    // an extra 16pt of breathing room so it doesn't crowd the bottom of the page.
    .padding(.bottom, 32)
    .background(
      // In Glass mode the composer shares the chat message list's exact wash
      // (`chromeGlassTint(0.22)`) over the pane's glass, so "Send a message" reads
      // as the same surface as the chat above it instead of a distinct lighter
      // band. Overlay/side modes keep their own opaque, theme-aware fills.
      chatLayoutMode == .glass
        ? AnyShapeStyle(palette.chromeGlassTint(0.22))
        : (palette.isLight
          ? (chatLayoutMode == .overlay
            ? AnyShapeStyle(Color(white: 0.97).opacity(0.92))
            : AnyShapeStyle(Color(white: 0.99).opacity(0.96)))
          : (chatLayoutMode == .overlay
            ? AnyShapeStyle(Color(white: 0.13).opacity(0.90))
            : AnyShapeStyle(palette.chatSideSurface)))
    )
  }

}
