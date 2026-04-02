import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case spanish = "es"
    case french = "fr"
    case german = "de"
    case portuguese = "pt"
    case italian = "it"
    case japanese = "ja"
    case chinese = "zh"
    case korean = "ko"
    case russian = "ru"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .english: "English"
        case .spanish: "Español"
        case .french: "Français"
        case .german: "Deutsch"
        case .portuguese: "Português"
        case .italian: "Italiano"
        case .japanese: "日本語"
        case .chinese: "中文"
        case .korean: "한국어"
        case .russian: "Русский"
        }
    }

    static func detect() -> AppLanguage {
        guard let preferred = Locale.preferredLanguages.first else { return .english }
        let code = String(preferred.prefix(2))
        return AppLanguage(rawValue: code) ?? .english
    }
}

struct L10n {
    let language: AppLanguage

    // MARK: - App Info

    var appDescription: String {
        switch language {
        case .english: "Ekual applies real-time loudness equalization to all system audio. It compresses loud sounds and boosts quiet ones, so you never have to reach for the volume — movies, music, games, and calls all play at a comfortable, consistent level."
        case .spanish: "Ekual aplica ecualización de volumen en tiempo real a todo el audio del sistema. Comprime los sonidos fuertes y amplifica los suaves, para que nunca tengas que ajustar el volumen — películas, música, juegos y llamadas suenan a un nivel cómodo y constante."
        case .french: "Ekual applique une égalisation du volume en temps réel à tout l'audio du système. Il compresse les sons forts et amplifie les sons faibles, pour que vous n'ayez jamais à toucher le volume — films, musique, jeux et appels jouent à un niveau confortable et constant."
        case .german: "Ekual wendet Echtzeit-Lautstärkeausgleich auf das gesamte Systemaudio an. Es komprimiert laute und verstärkt leise Töne, sodass Sie nie den Lautstärkeregler anfassen müssen — Filme, Musik, Spiele und Anrufe laufen auf einem angenehmen, gleichmäßigen Pegel."
        case .portuguese: "Ekual aplica equalização de volume em tempo real a todo o áudio do sistema. Comprime sons altos e amplifica os baixos, para que você nunca precise ajustar o volume — filmes, música, jogos e chamadas tocam em um nível confortável e consistente."
        case .italian: "Ekual applica l'equalizzazione del volume in tempo reale a tutto l'audio di sistema. Comprime i suoni forti e amplifica quelli deboli, così non devi mai toccare il volume — film, musica, giochi e chiamate suonano a un livello confortevole e costante."
        case .japanese: "Ekualはシステム全体の音声にリアルタイムのラウドネス均等化を適用します。大きな音を圧縮し、小さな音を増幅するため、音量調節の必要がありません。映画、音楽、ゲーム、通話がすべて快適で一定の音量で再生されます。"
        case .chinese: "Ekual对所有系统音频实时应用响度均衡。它压缩大声的声音并提升安静的声音，这样您就不必不断调节音量——电影、音乐、游戏和通话都能以舒适、一致的水平播放。"
        case .korean: "Ekual은 모든 시스템 오디오에 실시간 라우드니스 이퀄라이제이션을 적용합니다. 큰 소리를 압축하고 작은 소리를 증폭하여 볼륨을 조절할 필요 없이 영화, 음악, 게임, 통화가 편안하고 일정한 수준으로 재생됩니다."
        case .russian: "Ekual применяет выравнивание громкости в реальном времени ко всему системному аудио. Он сжимает громкие звуки и усиливает тихие, чтобы вам никогда не приходилось регулировать громкость — фильмы, музыка, игры и звонки воспроизводятся на комфортном, постоянном уровне."
        }
    }

    // MARK: - Status

    var statusActive: String {
        switch language {
        case .english: "Loudness Equalization Active"
        case .spanish: "Ecualización de Volumen Activa"
        case .french: "Égalisation du Volume Active"
        case .german: "Lautstärkeausgleich Aktiv"
        case .portuguese: "Equalização de Volume Ativa"
        case .italian: "Equalizzazione Volume Attiva"
        case .japanese: "ラウドネス均等化オン"
        case .chinese: "响度均衡已开启"
        case .korean: "라우드니스 이퀄라이제이션 활성"
        case .russian: "Выравнивание громкости активно"
        }
    }

    var statusOff: String {
        switch language {
        case .english: "Off"
        case .spanish: "Apagado"
        case .french: "Désactivé"
        case .german: "Aus"
        case .portuguese: "Desligado"
        case .italian: "Disattivo"
        case .japanese: "オフ"
        case .chinese: "关闭"
        case .korean: "꺼짐"
        case .russian: "Выключено"
        }
    }

    func switchingTo(_ device: String) -> String {
        switch language {
        case .english: "Switching to \(device)..."
        case .spanish: "Cambiando a \(device)..."
        case .french: "Basculement vers \(device)..."
        case .german: "Wechsel zu \(device)..."
        case .portuguese: "Mudando para \(device)..."
        case .italian: "Passaggio a \(device)..."
        case .japanese: "\(device) に切替中..."
        case .chinese: "正在切换到 \(device)..."
        case .korean: "\(device)(으)로 전환 중..."
        case .russian: "Переключение на \(device)..."
        }
    }

    // MARK: - Labels

    var outputDevice: String {
        switch language {
        case .english: "Output"
        case .spanish: "Salida"
        case .french: "Sortie"
        case .german: "Ausgabe"
        case .portuguese: "Saída"
        case .italian: "Uscita"
        case .japanese: "出力"
        case .chinese: "输出"
        case .korean: "출력"
        case .russian: "Выход"
        }
    }

    var systemDefault: String {
        switch language {
        case .english: "System Default"
        case .spanish: "Predeterminado"
        case .french: "Par Défaut"
        case .german: "Systemstandard"
        case .portuguese: "Padrão do Sistema"
        case .italian: "Predefinito"
        case .japanese: "システムデフォルト"
        case .chinese: "系统默认"
        case .korean: "시스템 기본값"
        case .russian: "По умолчанию"
        }
    }

    var preset: String {
        switch language {
        case .english: "Preset"
        case .spanish: "Preajuste"
        case .french: "Préréglage"
        case .german: "Voreinstellung"
        case .portuguese: "Predefinição"
        case .italian: "Preset"
        case .japanese: "プリセット"
        case .chinese: "预设"
        case .korean: "프리셋"
        case .russian: "Пресет"
        }
    }

    var releaseTime: String {
        switch language {
        case .english: "Release Time"
        case .spanish: "Tiempo de Liberación"
        case .french: "Temps de Relâchement"
        case .german: "Ausklingzeit"
        case .portuguese: "Tempo de Liberação"
        case .italian: "Tempo di Rilascio"
        case .japanese: "リリースタイム"
        case .chinese: "释放时间"
        case .korean: "릴리스 타임"
        case .russian: "Время возврата"
        }
    }

    var boost: String {
        switch language {
        case .english: "Boost"
        case .spanish: "Ganancia"
        case .french: "Gain"
        case .german: "Verstärkung"
        case .portuguese: "Ganho"
        case .italian: "Guadagno"
        case .japanese: "ブースト"
        case .chinese: "增益"
        case .korean: "부스트"
        case .russian: "Усиление"
        }
    }

    var threshold: String {
        switch language {
        case .english: "Threshold"
        case .spanish: "Umbral"
        case .french: "Seuil"
        case .german: "Schwellenwert"
        case .portuguese: "Limiar"
        case .italian: "Soglia"
        case .japanese: "閾値"
        case .chinese: "阈值"
        case .korean: "임계값"
        case .russian: "Порог"
        }
    }

    var meters: String {
        switch language {
        case .english: "Level Meters"
        case .spanish: "Medidores"
        case .french: "Indicateurs"
        case .german: "Pegelanzeige"
        case .portuguese: "Medidores"
        case .italian: "Indicatori"
        case .japanese: "レベルメーター"
        case .chinese: "电平表"
        case .korean: "레벨 미터"
        case .russian: "Индикаторы"
        }
    }

    var input: String {
        switch language {
        case .english: "Input"
        case .spanish: "Entrada"
        case .french: "Entrée"
        case .german: "Eingang"
        case .portuguese: "Entrada"
        case .italian: "Ingresso"
        case .japanese: "入力"
        case .chinese: "输入"
        case .korean: "입력"
        case .russian: "Вход"
        }
    }

    var output: String {
        switch language {
        case .english: "Output"
        case .spanish: "Salida"
        case .french: "Sortie"
        case .german: "Ausgang"
        case .portuguese: "Saída"
        case .italian: "Uscita"
        case .japanese: "出力"
        case .chinese: "输出"
        case .korean: "출력"
        case .russian: "Выход"
        }
    }

    // MARK: - Options

    var launchAtLogin: String {
        switch language {
        case .english: "Launch at Login"
        case .spanish: "Iniciar con el sistema"
        case .french: "Lancer au démarrage"
        case .german: "Beim Anmelden starten"
        case .portuguese: "Iniciar com o sistema"
        case .italian: "Avvia al login"
        case .japanese: "ログイン時に起動"
        case .chinese: "登录时启动"
        case .korean: "로그인 시 실행"
        case .russian: "Запуск при входе"
        }
    }

    var autoStart: String {
        switch language {
        case .english: "Auto-start on launch"
        case .spanish: "Iniciar automáticamente"
        case .french: "Démarrage automatique"
        case .german: "Automatisch starten"
        case .portuguese: "Iniciar automaticamente"
        case .italian: "Avvio automatico"
        case .japanese: "起動時に自動開始"
        case .chinese: "启动时自动开始"
        case .korean: "실행 시 자동 시작"
        case .russian: "Автозапуск"
        }
    }

    var autoStartPermission: String {
        switch language {
        case .english: "Auto-start is enabled. Grant audio permission to start automatically."
        case .spanish: "El inicio automático está activado. Concede permiso de audio para iniciar automáticamente."
        case .french: "Le démarrage automatique est activé. Accordez la permission audio pour démarrer automatiquement."
        case .german: "Automatischer Start ist aktiviert. Erteilen Sie die Audio-Berechtigung, um automatisch zu starten."
        case .portuguese: "O início automático está ativado. Conceda permissão de áudio para iniciar automaticamente."
        case .italian: "L'avvio automatico è attivato. Concedi il permesso audio per avviare automaticamente."
        case .japanese: "自動開始が有効です。自動的に開始するにはオーディオの権限を許可してください。"
        case .chinese: "自动启动已启用。请授予音频权限以自动启动。"
        case .korean: "자동 시작이 활성화되어 있습니다. 자동으로 시작하려면 오디오 권한을 부여하세요."
        case .russian: "Автозапуск включён. Предоставьте разрешение на аудио для автоматического запуска."
        }
    }

    var globalShortcutToggle: String {
        switch language {
        case .english: "Global Shortcut"
        case .spanish: "Atajo Global"
        case .french: "Raccourci Global"
        case .german: "Globales Tastenkürzel"
        case .portuguese: "Atalho Global"
        case .italian: "Scorciatoia Globale"
        case .japanese: "グローバルショートカット"
        case .chinese: "全局快捷键"
        case .korean: "전역 단축키"
        case .russian: "Глобальное сочетание"
        }
    }

    var pressKeys: String {
        switch language {
        case .english: "Press keys..."
        case .spanish: "Pulsa teclas..."
        case .french: "Appuyez..."
        case .german: "Tasten drücken..."
        case .portuguese: "Pressione..."
        case .italian: "Premi tasti..."
        case .japanese: "キーを押す..."
        case .chinese: "按键..."
        case .korean: "키 입력..."
        case .russian: "Нажмите..."
        }
    }

    var excludedApps: String {
        switch language {
        case .english: "Excluded Apps"
        case .spanish: "Apps Excluidas"
        case .french: "Apps Exclues"
        case .german: "Ausgeschlossene Apps"
        case .portuguese: "Apps Excluídos"
        case .italian: "App Escluse"
        case .japanese: "除外アプリ"
        case .chinese: "排除的应用"
        case .korean: "제외된 앱"
        case .russian: "Исключённые приложения"
        }
    }

    var noAppsRunning: String {
        switch language {
        case .english: "No audio apps detected"
        case .spanish: "No se detectaron apps de audio"
        case .french: "Aucune app audio détectée"
        case .german: "Keine Audio-Apps erkannt"
        case .portuguese: "Nenhum app de áudio detectado"
        case .italian: "Nessuna app audio rilevata"
        case .japanese: "オーディオアプリが見つかりません"
        case .chinese: "未检测到音频应用"
        case .korean: "오디오 앱이 감지되지 않음"
        case .russian: "Аудио-приложения не обнаружены"
        }
    }

    var resetToDefaults: String {
        switch language {
        case .english: "Reset to Defaults"
        case .spanish: "Restablecer"
        case .french: "Réinitialiser"
        case .german: "Zurücksetzen"
        case .portuguese: "Restaurar Padrões"
        case .italian: "Ripristina"
        case .japanese: "初期値に戻す"
        case .chinese: "恢复默认"
        case .korean: "기본값 복원"
        case .russian: "Сбросить"
        }
    }

    var quit: String {
        switch language {
        case .english: "Quit"
        case .spanish: "Salir"
        case .french: "Quitter"
        case .german: "Beenden"
        case .portuguese: "Sair"
        case .italian: "Esci"
        case .japanese: "終了"
        case .chinese: "退出"
        case .korean: "종료"
        case .russian: "Выход"
        }
    }

    // MARK: - Preset names

    func builtInPresetName(_ preset: BuiltInPreset) -> String {
        switch preset {
        case .light:
            switch language {
            case .english: "Light"
            case .spanish: "Ligero"
            case .french: "Léger"
            case .german: "Leicht"
            case .portuguese: "Leve"
            case .italian: "Leggero"
            case .japanese: "ライト"
            case .chinese: "轻度"
            case .korean: "가벼움"
            case .russian: "Лёгкий"
            }
        case .medium:
            switch language {
            case .english: "Medium"
            case .spanish: "Medio"
            case .french: "Moyen"
            case .german: "Mittel"
            case .portuguese: "Médio"
            case .italian: "Medio"
            case .japanese: "ミディアム"
            case .chinese: "中度"
            case .korean: "보통"
            case .russian: "Средний"
            }
        case .heavy:
            switch language {
            case .english: "Heavy"
            case .spanish: "Fuerte"
            case .french: "Fort"
            case .german: "Stark"
            case .portuguese: "Pesado"
            case .italian: "Pesante"
            case .japanese: "ヘビー"
            case .chinese: "重度"
            case .korean: "강함"
            case .russian: "Сильный"
            }
        }
    }

    var customModified: String {
        switch language {
        case .english: "Custom"
        case .spanish: "Personalizado"
        case .french: "Personnalisé"
        case .german: "Benutzerdefiniert"
        case .portuguese: "Personalizado"
        case .italian: "Personalizzato"
        case .japanese: "カスタム"
        case .chinese: "自定义"
        case .korean: "사용자 정의"
        case .russian: "Пользовательский"
        }
    }

    var savePreset: String {
        switch language {
        case .english: "Save Preset"
        case .spanish: "Guardar ajuste"
        case .french: "Enregistrer le préréglage"
        case .german: "Voreinstellung speichern"
        case .portuguese: "Salvar predefinição"
        case .italian: "Salva preset"
        case .japanese: "プリセットを保存"
        case .chinese: "保存预设"
        case .korean: "프리셋 저장"
        case .russian: "Сохранить пресет"
        }
    }

    var presetName_: String {
        switch language {
        case .english: "Preset Name"
        case .spanish: "Nombre del ajuste"
        case .french: "Nom du préréglage"
        case .german: "Name der Voreinstellung"
        case .portuguese: "Nome da predefinição"
        case .italian: "Nome del preset"
        case .japanese: "プリセット名"
        case .chinese: "预设名称"
        case .korean: "프리셋 이름"
        case .russian: "Название пресета"
        }
    }

    var save: String {
        switch language {
        case .english: "Save"
        case .spanish: "Guardar"
        case .french: "Enregistrer"
        case .german: "Speichern"
        case .portuguese: "Salvar"
        case .italian: "Salva"
        case .japanese: "保存"
        case .chinese: "保存"
        case .korean: "저장"
        case .russian: "Сохранить"
        }
    }

    var cancel: String {
        switch language {
        case .english: "Cancel"
        case .spanish: "Cancelar"
        case .french: "Annuler"
        case .german: "Abbrechen"
        case .portuguese: "Cancelar"
        case .italian: "Annulla"
        case .japanese: "キャンセル"
        case .chinese: "取消"
        case .korean: "취소"
        case .russian: "Отмена"
        }
    }

    var rename: String {
        switch language {
        case .english: "Rename"
        case .spanish: "Renombrar"
        case .french: "Renommer"
        case .german: "Umbenennen"
        case .portuguese: "Renomear"
        case .italian: "Rinomina"
        case .japanese: "名前を変更"
        case .chinese: "重命名"
        case .korean: "이름 변경"
        case .russian: "Переименовать"
        }
    }

    var delete: String {
        switch language {
        case .english: "Delete"
        case .spanish: "Eliminar"
        case .french: "Supprimer"
        case .german: "Löschen"
        case .portuguese: "Excluir"
        case .italian: "Elimina"
        case .japanese: "削除"
        case .chinese: "删除"
        case .korean: "삭제"
        case .russian: "Удалить"
        }
    }

    // MARK: - Tooltips

    var releaseTimeTooltip: String {
        switch language {
        case .english: "How quickly the volume recovers after a loud sound. Longer values give smoother, more natural leveling."
        case .spanish: "Qué tan rápido se recupera el volumen después de un sonido fuerte. Valores más largos dan una nivelación más suave y natural."
        case .french: "Vitesse de récupération du volume après un son fort. Des valeurs plus longues donnent un nivellement plus doux et naturel."
        case .german: "Wie schnell sich die Lautstärke nach einem lauten Ton erholt. Längere Werte ergeben eine sanftere, natürlichere Nivellierung."
        case .portuguese: "Quão rápido o volume se recupera após um som alto. Valores mais longos proporcionam um nivelamento mais suave e natural."
        case .italian: "Quanto velocemente il volume si riprende dopo un suono forte. Valori più lunghi danno un livellamento più morbido e naturale."
        case .japanese: "大きな音の後、音量がどれだけ早く回復するか。長い値はより滑らかで自然なレベリングを実現します。"
        case .chinese: "音量在大声之后恢复的速度。较长的值会产生更平滑、更自然的调平效果。"
        case .korean: "큰 소리 후 볼륨이 얼마나 빨리 회복되는지. 긴 값은 더 부드럽고 자연스러운 레벨링을 제공합니다."
        case .russian: "Как быстро восстанавливается громкость после громкого звука. Большие значения дают более плавное и естественное выравнивание."
        }
    }

    var boostTooltip: String {
        switch language {
        case .english: "Amplifies quiet sounds to make them louder. Higher values bring up soft audio more, but too much can cause distortion."
        case .spanish: "Amplifica los sonidos suaves para hacerlos más fuertes. Valores más altos amplifican más el audio suave, pero demasiado puede causar distorsión."
        case .french: "Amplifie les sons faibles pour les rendre plus forts. Des valeurs élevées augmentent plus l'audio faible, mais trop peut causer de la distorsion."
        case .german: "Verstärkt leise Töne, um sie lauter zu machen. Höhere Werte heben leises Audio stärker an, aber zu viel kann Verzerrung verursachen."
        case .portuguese: "Amplifica sons suaves para torná-los mais altos. Valores mais altos elevam mais o áudio suave, mas demais pode causar distorção."
        case .italian: "Amplifica i suoni deboli per renderli più forti. Valori più alti alzano di più l'audio debole, ma troppo può causare distorsione."
        case .japanese: "静かな音を増幅して大きくします。高い値はソフトな音声をより引き上げますが、大きすぎると歪みが生じる可能性があります。"
        case .chinese: "放大安静的声音使其更响亮。较高的值会更多地提升柔和音频，但过多可能导致失真。"
        case .korean: "조용한 소리를 증폭하여 더 크게 만듭니다. 높은 값은 부드러운 오디오를 더 많이 올리지만, 너무 많으면 왜곡이 발생할 수 있습니다."
        case .russian: "Усиливает тихие звуки. Более высокие значения сильнее поднимают тихое аудио, но слишком большое усиление может вызвать искажения."
        }
    }

    var thresholdTooltip: String {
        switch language {
        case .english: "The volume level above which compression kicks in. Lower values compress more of the audio range, giving a more even output."
        case .spanish: "El nivel de volumen por encima del cual se activa la compresión. Valores más bajos comprimen más del rango de audio, dando una salida más uniforme."
        case .french: "Le niveau de volume au-dessus duquel la compression s'active. Des valeurs plus basses compriment plus de la plage audio, donnant une sortie plus uniforme."
        case .german: "Der Lautstärkepegel, ab dem die Kompression einsetzt. Niedrigere Werte komprimieren mehr vom Audiobereich und erzeugen eine gleichmäßigere Ausgabe."
        case .portuguese: "O nível de volume acima do qual a compressão é ativada. Valores mais baixos comprimem mais da faixa de áudio, dando uma saída mais uniforme."
        case .italian: "Il livello di volume sopra il quale la compressione si attiva. Valori più bassi comprimono più della gamma audio, dando un'uscita più uniforme."
        case .japanese: "圧縮が作動する音量レベル。低い値はより広い音声範囲を圧縮し、より均一な出力を実現します。"
        case .chinese: "压缩开始生效的音量水平。较低的值会压缩更多的音频范围，产生更均匀的输出。"
        case .korean: "압축이 시작되는 볼륨 수준. 낮은 값은 더 많은 오디오 범위를 압축하여 더 균일한 출력을 제공합니다."
        case .russian: "Уровень громкости, выше которого включается компрессия. Более низкие значения сжимают больший диапазон, давая более ровный выход."
        }
    }

    // MARK: - Language picker

    var language_: String {
        switch language {
        case .english: "Language"
        case .spanish: "Idioma"
        case .french: "Langue"
        case .german: "Sprache"
        case .portuguese: "Idioma"
        case .italian: "Lingua"
        case .japanese: "言語"
        case .chinese: "语言"
        case .korean: "언어"
        case .russian: "Язык"
        }
    }

    // MARK: - Permission

    var grantPermission: String {
        switch language {
        case .english: "Grant Audio Access"
        case .spanish: "Conceder Acceso al Audio"
        case .french: "Autoriser l'accès audio"
        case .german: "Audiozugriff erlauben"
        case .portuguese: "Conceder Acesso ao Áudio"
        case .italian: "Concedi Accesso Audio"
        case .japanese: "オーディオアクセスを許可"
        case .chinese: "授予音频访问权限"
        case .korean: "오디오 접근 허용"
        case .russian: "Разрешить доступ к аудио"
        }
    }

    var permissionExplanation: String {
        switch language {
        case .english: "macOS requires audio capture permission for Ekual to process system audio. Your audio is never recorded, stored, or sent anywhere — it is processed entirely in real-time on your device and immediately sent to your speakers."
        case .spanish: "macOS requiere permiso de captura de audio para que Ekual procese el audio del sistema. Tu audio nunca se graba, almacena ni envía a ningún lugar — se procesa completamente en tiempo real en tu dispositivo y se envía directamente a tus altavoces."
        case .french: "macOS nécessite une autorisation de capture audio pour qu'Ekual traite l'audio du système. Votre audio n'est jamais enregistré, stocké ou envoyé nulle part — il est traité entièrement en temps réel sur votre appareil et envoyé directement à vos haut-parleurs."
        case .german: "macOS benötigt eine Audioaufnahme-Berechtigung, damit Ekual das Systemaudio verarbeiten kann. Ihr Audio wird niemals aufgenommen, gespeichert oder irgendwohin gesendet — es wird vollständig in Echtzeit auf Ihrem Gerät verarbeitet und direkt an Ihre Lautsprecher gesendet."
        case .portuguese: "O macOS requer permissão de captura de áudio para que o Ekual processe o áudio do sistema. Seu áudio nunca é gravado, armazenado ou enviado a qualquer lugar — é processado inteiramente em tempo real no seu dispositivo e enviado diretamente aos seus alto-falantes."
        case .italian: "macOS richiede il permesso di cattura audio per permettere a Ekual di elaborare l'audio di sistema. Il tuo audio non viene mai registrato, archiviato o inviato da nessuna parte — viene elaborato interamente in tempo reale sul tuo dispositivo e inviato direttamente ai tuoi altoparlanti."
        case .japanese: "macOSはEkualがシステムオーディオを処理するためにオーディオキャプチャの許可を必要とします。音声は録音、保存、送信されることはありません。デバイス上でリアルタイムに処理され、直接スピーカーに送られます。"
        case .chinese: "macOS需要音频捕获权限才能让Ekual处理系统音频。您的音频永远不会被录制、存储或发送到任何地方——它完全在您的设备上实时处理并直接发送到您的扬声器。"
        case .korean: "macOS는 Ekual이 시스템 오디오를 처리하기 위해 오디오 캡처 권한이 필요합니다. 오디오는 절대 녹음, 저장되거나 어디로도 전송되지 않습니다. 기기에서 실시간으로 처리되어 바로 스피커로 전송됩니다."
        case .russian: "macOS требует разрешение на захват аудио, чтобы Ekual мог обрабатывать системный звук. Ваше аудио никогда не записывается, не сохраняется и не отправляется никуда — оно полностью обрабатывается в реальном времени на вашем устройстве и отправляется прямо на динамики."
        }
    }

    var permissionGranted: String {
        switch language {
        case .english: "Audio access granted"
        case .spanish: "Acceso al audio concedido"
        case .french: "Accès audio accordé"
        case .german: "Audiozugriff gewährt"
        case .portuguese: "Acesso ao áudio concedido"
        case .italian: "Accesso audio concesso"
        case .japanese: "オーディオアクセス許可済み"
        case .chinese: "音频访问已授权"
        case .korean: "오디오 접근 허용됨"
        case .russian: "Доступ к аудио разрешён"
        }
    }

    var startEkual: String {
        switch language {
        case .english: "Start Ekual"
        case .spanish: "Iniciar Ekual"
        case .french: "Démarrer Ekual"
        case .german: "Ekual starten"
        case .portuguese: "Iniciar Ekual"
        case .italian: "Avvia Ekual"
        case .japanese: "Ekualを開始"
        case .chinese: "启动Ekual"
        case .korean: "Ekual 시작"
        case .russian: "Запустить Ekual"
        }
    }

    var stopEkual: String {
        switch language {
        case .english: "Stop Ekual"
        case .spanish: "Detener Ekual"
        case .french: "Arrêter Ekual"
        case .german: "Ekual stoppen"
        case .portuguese: "Parar Ekual"
        case .italian: "Ferma Ekual"
        case .japanese: "Ekualを停止"
        case .chinese: "停止Ekual"
        case .korean: "Ekual 중지"
        case .russian: "Остановить Ekual"
        }
    }

    var tryAgain: String {
        switch language {
        case .english: "Try Again"
        case .spanish: "Reintentar"
        case .french: "Réessayer"
        case .german: "Erneut versuchen"
        case .portuguese: "Tentar Novamente"
        case .italian: "Riprova"
        case .japanese: "再試行"
        case .chinese: "重试"
        case .korean: "다시 시도"
        case .russian: "Повторить"
        }
    }

    // MARK: - License

    var licenseRequired: String {
        switch language {
        case .english: "Enter your license key to use Ekual."
        case .spanish: "Ingresa tu clave de licencia para usar Ekual."
        case .french: "Entrez votre clé de licence pour utiliser Ekual."
        case .german: "Geben Sie Ihren Lizenzschlüssel ein, um Ekual zu verwenden."
        case .portuguese: "Insira sua chave de licença para usar o Ekual."
        case .italian: "Inserisci la tua chiave di licenza per usare Ekual."
        case .japanese: "Ekualを使用するにはライセンスキーを入力してください。"
        case .chinese: "请输入您的许可证密钥以使用Ekual。"
        case .korean: "Ekual을 사용하려면 라이선스 키를 입력하세요."
        case .russian: "Введите лицензионный ключ для использования Ekual."
        }
    }

    var licenseKeyPlaceholder: String {
        switch language {
        case .english: "License Key"
        case .spanish: "Clave de Licencia"
        case .french: "Clé de Licence"
        case .german: "Lizenzschlüssel"
        case .portuguese: "Chave de Licença"
        case .italian: "Chiave di Licenza"
        case .japanese: "ライセンスキー"
        case .chinese: "许可证密钥"
        case .korean: "라이선스 키"
        case .russian: "Лицензионный ключ"
        }
    }

    var invalidLicenseKey: String {
        switch language {
        case .english: "Invalid license key. Please check and try again."
        case .spanish: "Clave de licencia inválida. Verifica e intenta de nuevo."
        case .french: "Clé de licence invalide. Vérifiez et réessayez."
        case .german: "Ungültiger Lizenzschlüssel. Bitte überprüfen und erneut versuchen."
        case .portuguese: "Chave de licença inválida. Verifique e tente novamente."
        case .italian: "Chiave di licenza non valida. Controlla e riprova."
        case .japanese: "無効なライセンスキーです。確認してもう一度お試しください。"
        case .chinese: "无效的许可证密钥。请检查后重试。"
        case .korean: "잘못된 라이선스 키입니다. 확인 후 다시 시도하세요."
        case .russian: "Недействительный лицензионный ключ. Проверьте и попробуйте снова."
        }
    }

    var activate: String {
        switch language {
        case .english: "Activate"
        case .spanish: "Activar"
        case .french: "Activer"
        case .german: "Aktivieren"
        case .portuguese: "Ativar"
        case .italian: "Attiva"
        case .japanese: "アクティベート"
        case .chinese: "激活"
        case .korean: "활성화"
        case .russian: "Активировать"
        }
    }

    var buyEkual: String {
        switch language {
        case .english: "Buy Ekual"
        case .spanish: "Comprar Ekual"
        case .french: "Acheter Ekual"
        case .german: "Ekual kaufen"
        case .portuguese: "Comprar Ekual"
        case .italian: "Acquista Ekual"
        case .japanese: "Ekualを購入"
        case .chinese: "购买Ekual"
        case .korean: "Ekual 구매"
        case .russian: "Купить Ekual"
        }
    }

    var deactivateLicense: String {
        switch language {
        case .english: "Deactivate License"
        case .spanish: "Desactivar Licencia"
        case .french: "Désactiver la Licence"
        case .german: "Lizenz deaktivieren"
        case .portuguese: "Desativar Licença"
        case .italian: "Disattiva Licenza"
        case .japanese: "ライセンスを無効化"
        case .chinese: "停用许可证"
        case .korean: "라이선스 비활성화"
        case .russian: "Деактивировать лицензию"
        }
    }

    var menuBarHint: String {
        switch language {
        case .english: "Ekual lives in your menu bar.\nClick the waveform icon to access controls anytime."
        case .spanish: "Ekual vive en tu barra de menú.\nHaz clic en el icono de onda para acceder a los controles."
        case .french: "Ekual se trouve dans votre barre de menus.\nCliquez sur l'icône de forme d'onde pour accéder aux contrôles."
        case .german: "Ekual befindet sich in Ihrer Menüleiste.\nKlicken Sie auf das Wellenform-Symbol für die Steuerung."
        case .portuguese: "Ekual fica na barra de menus.\nClique no ícone de onda para acessar os controles."
        case .italian: "Ekual si trova nella barra dei menu.\nClicca sull'icona dell'onda per accedere ai controlli."
        case .japanese: "Ekualはメニューバーにあります。\n波形アイコンをクリックしてコントロールにアクセスできます。"
        case .chinese: "Ekual位于菜单栏中。\n点击波形图标即可访问控制界面。"
        case .korean: "Ekual은 메뉴 막대에 있습니다.\n파형 아이콘을 클릭하여 컨트롤에 접근하세요."
        case .russian: "Ekual находится в строке меню.\nНажмите на значок волны для доступа к настройкам."
        }
    }
}
