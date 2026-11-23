# SYNTRIX: aggiornamento e compilazione

Avvio automatico su Windows 10/11 x64:

```powershell
.\maintenance\Update-Syntrix.ps1
```

In alternativa, con Python 3.11 o superiore:

```powershell
python maintenance/update_syntrix.py
```

Il canale predefinito `auto` seleziona la release pubblicata più recente, includendo prerelease e nightly. Non fissa una versione: una nuova release stabile successiva alla nightly viene selezionata automaticamente. Per la nightly confronta la data dell'eseguibile Windows e ricava il commit dalla corrispondente build CI x64 riuscita, evitando il tag Git potenzialmente obsoleto.

Opzioni PowerShell: `-Plan` mostra soltanto la selezione; `-Channel stable` esclude prerelease; `-Tag 1.5.3` sceglie una release esplicita; `-PrepareOnly` prepara e verifica i sorgenti senza compilare; `-Variant public` oppure `private` seleziona una variante (predefinito: entrambe). Python espone le opzioni equivalenti `--plan`, `--channel`, `--tag`, `--prepare-only`, `--variant`.

PowerShell procura Python se manca. La pipeline procura Git, Rust, Flutter, Visual Studio Build Tools/C++/Windows SDK, vcpkg e dipendenze native/Python secondo il workflow upstream. I download vengono verificati tramite hash ufficiali o firma Authenticode. Visual Studio può richiedere privilegi amministrativi o un riavvio: in quest'ultimo caso lo script si arresta e va rilanciato dopo il riavvio. Servono connessione Internet e spazio per SDK e compilazione. I bridge generati vengono recuperati dagli artifact CI e verificati; non viene eseguito il code generator.

Le personalizzazioni comprendono branding SYNTRIX e ripristino hide_cm: durante le sessioni autorizzate la finestra delle connessioni resta nascosta quando configurato; si apre su richiesta dalla tray. L'indicatore compatto è rimosso. Restano le richieste di autorizzazione necessarie. Le varianti pubblica e privata hanno profili e patch separati.

Cache, sorgenti temporanei, log ed eseguibili sono in `%LOCALAPPDATA%\SyntrixUpdater`; gli strumenti in `%USERPROFILE%\.syntrix-toolchain`. Gli eseguibili e ZIP verificati sono nella sottocartella `releases`, separati per variante, commit e patch. Ogni pacchetto include un rapporto e checksum. Non viene installato RustDesk e non vengono riavviati servizi o tray.

Su nuove versioni upstream una patch o una dipendenza può diventare incompatibile: la pipeline si arresta con un log invece di consegnare una build dichiarata corretta. Le verifiche automatiche non sostituiscono una prova manuale con una sessione remota.

Le build già consegnate restano in `release/tray-only-20261119` nelle due distribuzioni; `release/latest.json` le identifica. I materiali storici sono conservati sotto `Repository-Private/archive`. La pulizia rimuove cache ricreabili e build precedenti, preservando sorgenti, Git e ultimi pacchetti verificati.

Verifiche eseguite sugli script: test Python, analisi sintattica PowerShell e preparazione di entrambe le varianti sul commit della nightly corrente. La nuova pipeline completa e il bootstrap su un PC privo di strumenti non sono ancora stati eseguiti integralmente.
