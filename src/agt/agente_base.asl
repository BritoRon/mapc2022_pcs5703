/*
 * agente_base.asl
 *
 * Base comum a TODOS os agentes do time. E incluido no inicio dos arquivos
 * coordenador.asl, explorador.asl, worker.asl com a diretiva:
 *
 *     { include("agente_base.asl") }
 *
 * Aqui ficam:
 *   - templates JaCaMo padrao (CArtAgO + MOISE+)
 *   - planos universais (executar acao, esperar passo, log)
 *   - tratamento basico das percepcoes vindas do servidor MASSim 2022
 *
 * Comentarios em portugues por motivos didaticos. NAO mude o nome de planos
 * sem entender as implicacoes - alguns sao chamados pelo EISAdapter ou pela
 * runtime MOISE+.
 */

/* ===================================================================== */
/* INCLUDES PADRAO DO JACAMO                                              */
/* ===================================================================== */

/*
 * common-cartago.asl: define planos para focar em artefatos, listar
 *   workspaces, lidar com signals (eventos disparados pelo CArtAgO), etc.
 *
 * common-moise.asl: define planos para se vincular a um grupo, adotar
 *   papeis, listar esquemas, e comprometer-se com missoes.
 *
 * org-obedient.asl: faz o agente "obedecer" automaticamente as obrigacoes
 *   normativas - assim que uma norma vira obrigacao para ele, o agente
 *   adiciona o goal correspondente. SEM isso, voce teria que escrever
 *   manualmente +obligation(...) -> commitMission(...) etc.
 *
 * Esta combinacao e a forma "padrao JaCaMo" de fazer um agente que
 * automaticamente cumpre suas obrigacoes organizacionais.
 */
{ include("$jacamo/templates/common-cartago.asl") }
{ include("$jacamo/templates/common-moise.asl")   }
{ include("$moise/asl/org-obedient.asl")          }


/* ===================================================================== */
/* CRENCAS INICIAIS                                                       */
/* ===================================================================== */

/*
 * Estas crencas sao parametros do nosso time que provavelmente vao mudar
 * conforme refinamos a estrategia. Manter centralizadas aqui facilita
 * tunning (item 5 do template de relatorio: "Estrategia para time de
 * agentes").
 */
distancia_visao(5).            // raio de visao do agente (Manhattan), do cenario
limite_passos_retry(3).        // tentativas antes de desistir de uma acao
energia_minima_seguranca(20).  // abaixo disso o agente prioriza recarregar

/*
 * Ultimo actionID ja tratado. A ponte EIS reprocessa cada passo do servidor
 * ~2x (re-dispara +actionID para o mesmo ID), o que fazia o agente enviar
 * varias acoes por passo e desperdicar passos (no_action). Os planos
 * +actionID usam isto para agir UMA unica vez por actionID. Comeca em -1.
 */
ultimo_action_id(-1).


/* ===================================================================== */
/* FLAGS DE ATIVACAO INCREMENTAL (proximos passos do README)              */
/* ===================================================================== */

/*
 * Os "proximos passos" do README sao construidos como esqueleto e ligados
 * UM DE CADA VEZ por estas flags. A ideia: o baseline (random walk + skip)
 * continua intacto; voce ACENDE um passo, testa, e so entao acende o
 * proximo. Passos que so criam crencas/observable properties (seguros)
 * ja vem LIGADOS; passos que enviam acoes ao servidor vem DESLIGADOS
 * (basta descomentar para ativar).
 */
flag_mapear.               // passo 1: registrar mapa em coords absolutas (SEGURO, ligado)
flag_identificar.          // passo 2: identificar companheiros por posicao-espelho (LIGADO)
flag_selecionar_tarefa.    // passo 3: coordenador escolhe e anuncia a task-alvo (LIGADO)
flag_virar_worker.         // passo 3: explorador vira worker e busca/monta o bloco (LIGADO)
flag_submeter.             // passo 3/4: worker submete a tarefa numa goal zone (LIGADO)


/* ===================================================================== */
/* PASSO 1 (infra): RASTREIO DE POSICAO ABSOLUTA                          */
/* ===================================================================== */

/*
 * As percepcoes do servidor sao RELATIVAS a posicao do agente naquele step
 * (absolutePosition: false). Para construir um mapa estavel, o agente
 * mantem sua propria posicao num referencial absoluto cuja ORIGEM (0,0) e
 * onde ele nasceu. A cada move bem-sucedido, somamos o deslocamento.
 *
 * CONVENCAO DE EIXOS (conferir em ../massim_2022/docs/scenario.md):
 *   x cresce para LESTE (e),  y cresce para SUL (s).
 *   Logo: n = (0,-1), s = (0,+1), e = (+1,0), w = (-1,0).
 */
posicao(0, 0).
delta(n, 0, -1).
delta(s, 0,  1).
delta(e,  1, 0).
delta(w, -1, 0).

/*
 * Atualiza a posicao lendo o resultado da ultima acao. So conta quando:
 *   - a ultima acao foi um move,
 *   - o servidor reportou success,
 *   - foi um move de UMA direcao (lista [D]).
 *
 * TODO: o cenario 2022 permite move com VARIAS direcoes (ex: move(n,e)) -
 *       lastActionParams viria [n,e]. Quando a estrategia usar isso, somar
 *       todos os deltas em sequencia aqui.
 */
+!atualizar_posicao
    : lastAction(move) & lastActionResult(success)
      & lastActionParams([D]) & delta(D, DX, DY) & posicao(X, Y)
    <- NX = X + DX;
       NY = Y + DY;
       -+posicao(NX, NY).
// Caso default: primeira jogada, acao nao foi move, ou move falhou -> nada.
+!atualizar_posicao <- true.


/* ===================================================================== */
/* PLANO UTILITARIO: EXECUTAR ACAO NO AMBIENTE EIS                        */
/* ===================================================================== */

/*
 * Executar uma acao no servidor MASSim e fazer um efeito colateral em Jason.
 *
 * Em Jason+EIS, as acoes sao executadas chamando o nome da acao como uma
 * acao externa (e.g., move(n), skip, attach(s), etc). O EISAdapter
 * (src/java/jason/eis/EISAdapter.java) intercepta essa chamada via o
 * metodo executeAction(...) e converte em uma mensagem ActionMessage para
 * o servidor.
 *
 * Este plano e um wrapper conveniente que registra log antes/depois e
 * e o unico ponto onde TODAS as acoes do agente passam - util para auditar.
 *
 * Uso:
 *     !executar(move(n)).
 *     !executar(skip).
 *     !executar(attach(s)).
 */
+!executar(Acao) <-
    .my_name(Eu);
    .print("[",Eu,"] -> ", Acao);
    Acao.   // <-- aqui Jason chama a acao no ambiente EIS

/* ===================================================================== */
/* PERCEPCOES PADRAO RECEBIDAS DO SERVIDOR MASSIM                         */
/* ===================================================================== */

/*
 * O EISAdapter converte cada percept que vem do servidor em uma crenca
 * Jason. Os principais sao:
 *
 *   step(N)                    - passo atual da simulacao
 *   actionID(I)                - ID que devemos enviar de volta na acao
 *   timestamp(T)               - hora do servidor
 *   deadline(T)                - quando o servidor espera nossa acao
 *   score(S)                   - nossa pontuacao acumulada
 *   energy(E)                  - energia do agente
 *   role(NomeRoleMASSim)       - role MASSim atualmente adotado
 *   thing(X,Y,Tipo,Detalhe)    - alguma coisa visivel em (X,Y) relativo
 *   attached(X,Y)              - bloco anexado em (X,Y)
 *   task(Nome,Deadline,Reward, Reqs) - tarefa disponivel
 *   lastAction(Acao)           - ultima acao executada
 *   lastActionResult(R)        - resultado: success | failed | etc.
 *
 * Veja docs/eismassim.md no diretorio do servidor para a lista completa.
 *
 * Adicionamos abaixo planos triviais que reagem a ESSAS percepcoes -
 * basta para o esqueleto compilar e rodar. Os agentes especificos
 * (coordenador, explorador) sobrepoem esses planos com logica real.
 */

// Percept de inicio de simulacao (chega no SIM-START): role inicial,
// nome do time, etc. Aqui apenas registramos.
+name(Nome) <-
    .print("Servidor diz: meu nome no jogo e '", Nome, "'").

+team(NomeTime) <-
    .print("Faco parte do time '", NomeTime, "' no servidor").

+steps(N) <-
    .print("Esta simulacao tem ", N, " passos.").


// Quando o servidor nos avisa que a simulacao acabou:
+ranking(R) <-
    .print("SIM-END: terminamos em ", R, "o lugar.").


// [DEBUG] Confirma que o bridge observable property -> crenca funciona para
// os percepts do EIS (e nao so do QuadroEquipe).
+step(S) <- .print("[DBGstep] step=", S).


/* ===================================================================== */
/* PASSO 2: POSICAO COMPARTILHADA + IDENTIFICACAO POR POSICAO-ESPELHO     */
/* ===================================================================== */

/*
 * Publica a propria posicao (frame proprio) no QuadroEquipe a cada passo.
 * Vira a crenca pos_agente(Nome,X,Y) em todos os agentes do time.
 */
+!publicar_posicao : posicao(X, Y) <-
    .my_name(Eu);
    atualizar_pos_agente(Eu, X, Y).
+!publicar_posicao <- true.

/*
 * IDENTIFICACAO DE COMPANHEIROS (posicao-espelho).
 *
 * Cada frame tem origem (0,0) no spawn do agente. Se o agente i ve o colega
 * j em (rx,ry), entao j ve i em (-rx,-ry) (espelho). Trocando posicoes por
 * mensagem, calcula-se o offset entre os frames:
 *
 *   offset(j->i) = (rx,ry) + posicao_i - posicao_j     // ponto no frame de j
 *                                                       // + offset = ponto no frame de i
 *
 * Como i nao sabe QUEM viu, faz broadcast da observacao; quem se reconhece
 * pelo espelho responde com sua identidade/posicao e ja devolve o offset.
 */
+!identificar_companheiros : flag_identificar & team(MeuTime) & posicao(X, Y) <-
    .findall(c(RX, RY),
             (thing(RX, RY, entity, MeuTime) & (RX \== 0 | RY \== 0)),
             Colegas);
    !tratar_avistamento(Colegas, X, Y).
+!identificar_companheiros <- true.

// Exatamente UM colega a vista -> anuncia a observacao ao time.
+!tratar_avistamento([c(RX, RY)], X, Y) <-
    .my_name(Eu);
    .broadcast(tell, avistei_colega(Eu, X, Y, RX, RY)).
// Zero ou varios colegas -> ambiguo, nao tenta alinhar agora.
+!tratar_avistamento(_, _, _) <- true.

/*
 * Recebi o anuncio de um colega. Consome o sinal e processa (separado para
 * que o sinal seja sempre limpo, mesmo se o reconhecimento falhar).
 */
+avistei_colega(Outro, OX, OY, ORX, ORY) <-
    .abolish(avistei_colega(Outro, OX, OY, ORX, ORY));
    !processar_avistamento(Outro, OX, OY, ORX, ORY).

/*
 * Reconheco o Outro SE eu vejo um colega exatamente no espelho (-ORX,-ORY).
 * Entao calculo meu offset (frame do Outro -> meu) e devolvo a ele o offset
 * inverso (meu frame -> frame dele), para ambos alinharem.
 */
+!processar_avistamento(Outro, OX, OY, ORX, ORY)
    : flag_identificar & .my_name(Eu) & Outro \== Eu
      & team(MeuTime) & posicao(MX, MY)
      & MRX = 0 - ORX & MRY = 0 - ORY
      & thing(MRX, MRY, entity, MeuTime)
    <- DX = MRX + MX - OX;   DY = MRY + MY - OY;     // frame(Outro) -> meu frame
       -+offset_frame(Outro, DX, DY);
       RDX = OX - MX - MRX;  RDY = OY - MY - MRY;    // meu frame -> frame(Outro)
       .send(Outro, tell, seu_offset(Eu, RDX, RDY));
       .print("[ESPELHO] reconheci ", Outro,
              "; offset(", Outro, "->eu)=(", DX, ",", DY, ")").
// Nao reconheci (nao vejo no espelho ou ja me movi): ignora.
+!processar_avistamento(_, _, _, _, _) <- true.

/*
 * O colega me devolveu o offset do MEU frame para o frame dele. Guardo.
 */
+seu_offset(Outro, DX, DY) <-
    .abolish(seu_offset(Outro, DX, DY));
    -+offset_frame(Outro, DX, DY);
    .print("[ESPELHO] recebi offset: frame(", Outro, ")->meu = (", DX, ",", DY, ")").


/* ===================================================================== */
/* PASSO 2 (cont.): FRAME DE REFERENCIA E PROPAGACAO DE offset_ref        */
/* ===================================================================== */

/*
 * Frame de referencia do time (configuravel). Todas as descobertas sao
 * publicadas no QuadroEquipe NESTE frame, para que os mapas dos varios
 * exploradores se fundam (mesmo ponto fisico -> mesma coordenada).
 *
 * offset_ref(DX,DY) = transforma o frame PROPRIO no frame de referencia:
 *   ponto_no_frame_ref = ponto_no_frame_proprio + (DX,DY)
 * (ou seja, offset_ref = W_proprio - W_ref).
 */
frame_ref(explorador1).

/*
 * Anuncia o offset_ref a cada passo (inundacao). Tres casos:
 *  1. ja conheco meu offset_ref -> faco broadcast (para colegas derivarem o deles);
 *  2. sou o agente de referencia e ainda nao defini -> defino (0,0);
 *  3. ainda nao sei e nao sou a referencia -> nada (espero derivar).
 */
+!anunciar_offset_ref : offset_ref(X, Y) <-
    .my_name(Eu);
    .broadcast(tell, meu_offset_ref(Eu, X, Y)).
+!anunciar_offset_ref : frame_ref(R) & .my_name(R) & not offset_ref(_, _) <-
    +offset_ref(0, 0).
+!anunciar_offset_ref <- true.

// Log quando passo a conhecer meu offset_ref.
+offset_ref(X, Y) <- .print("[FRAME] meu offset_ref = (", X, ",", Y, ")").

/*
 * Recebi o offset_ref de um colega. Se ainda nao tenho o meu E ja conheco
 * o offset_frame ate esse colega, derivo o meu:
 *   W_eu - W_ref = (W_eu - W_outro) + (W_outro - W_ref) = -(offset_frame) + offset_ref_outro
 */
+meu_offset_ref(Outro, OX, OY) <-
    .abolish(meu_offset_ref(Outro, OX, OY));
    !derivar_offset_ref(Outro, OX, OY).
+!derivar_offset_ref(Outro, OX, OY)
    : not offset_ref(_, _) & .my_name(Eu) & Outro \== Eu & offset_frame(Outro, DX, DY)
    <- NX = OX - DX;  NY = OY - DY;
       +offset_ref(NX, NY);
       .print("[FRAME] derivei offset_ref via ", Outro).
+!derivar_offset_ref(_, _, _) <- true.


/* ===================================================================== */
/* DICA: COMO ENXERGAR O QUE O AGENTE ESTA "PENSANDO"                     */
/* ===================================================================== */

/*
 * Para inspecionar a base de crencas em runtime sem parar a simulacao,
 * use a console JaCaMo (jcm console) ou simplesmente adicione planos
 * de log dirigidos. Exemplos:
 *
 *     +!debug_crencas <-
 *         .findall(thing(X,Y,T,D), thing(X,Y,T,D), L);
 *         .print("Coisas que vejo agora: ", L).
 *
 *     +!debug_normas <-
 *         .findall(obligation(_,_,_,_), obligation(_,_,_,_), L);
 *         .print("Obrigacoes ativas: ", L).
 */
