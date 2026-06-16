/*
 * explorador.asl
 *
 * Agente que adota o papel social MOISE+ "explorer" no grupo do time.
 *
 * Funcao no esqueleto:
 *   - Recebe percepcoes do servidor e registra dispensers, taskboards e
 *     goal zones que enxergar (ainda em logging - a memoria persistente
 *     fica para a proxima iteracao).
 *   - Em cada passo escolhe um movimento simples (random walk).
 *
 * Para evoluir (item 5 do relatorio):
 *   - Substituir random walk pelo Spanning Tree Coverage (JaCaMo Builders
 *     §4.1) - eles mediram +70% de cobertura comparado ao espiral.
 *   - Compartilhar descobertas via o artefato `quadro` - escrever
 *     dispenser_descoberto(X,Y,Tipo) na blackboard quando ver um.
 *   - Trocar de papel para "worker" quando coletar 2 blocos.
 *     Isso e modelado pela compatibility from="explorer" to="worker"
 *     no org.xml e basta um adoptRole("worker") na hora certa.
 */

{ include("agente_base.asl") }


/* ===================================================================== */
/* META INICIAL                                                           */
/* ===================================================================== */

!iniciar.

+!iniciar <-
    .my_name(Eu);
    .print("Explorador ", Eu, " inicializado. Esperando simulacao comecar...").


/* ===================================================================== */
/* TRATAMENTO DE PERCEPCOES DO MUNDO                                      */
/* ===================================================================== */

/*
 * Quando o servidor MASSim manda thing(X,Y,Tipo,Detalhe), o EISAdapter
 * cria automaticamente uma crenca thing(X,Y,Tipo,Detalhe). Aqui podemos
 * reagir a percepcoes especificas. Mas CUIDADO:
 *
 *   1. Os percepts sao RELATIVOS a posicao do agente naquele step
 *      (ver docs/scenario.md -> "absolutePosition: false").
 *   2. As crencas sao adicionadas E REMOVIDAS pelo EISAdapter ao
 *      sincronizar com o estado atual - isso significa que +thing(...)
 *      dispara muitas vezes por passo. Nao gere log para cada uma.
 *
 * Para o esqueleto, vamos apenas logar UMA VEZ POR PASSO um resumo dos
 * objetos interessantes. Fazemos isso no plano +actionID abaixo.
 */


/* ===================================================================== */
/* CICLO DE PASSO                                                         */
/* ===================================================================== */

/*
 * Cada vez que o servidor anuncia o novo actionID, o agente:
 *   1. Atualiza sua posicao absoluta (passo 1, em agente_base.asl).
 *   2. Registra no mapa/quadro o que vir (passo 1).
 *   3. Tenta identificar companheiros a vista (passo 2).
 *   4. Loga um resumo do que enxerga.
 *   5. Decide a acao do passo e executa.
 *
 * O baseline ainda usa random walk em escolher_acao. As iteracoes
 * seguintes substituem isso por uma estrategia de cobertura inteligente.
 */
+actionID(ID) : ultimo_action_id(Last) & ID \== Last <-
    -+ultimo_action_id(ID);
    !atualizar_posicao;
    !publicar_posicao;
    !registrar_descobertas;
    !identificar_companheiros;
    !anunciar_offset_ref;
    !reset_pos_submit;
    !diag_worker;
    !diag_multi;
    !escolher_acao(Acao);
    !diag_explora(Acao);
    !executar(Acao);
    acao_concluida.
// libera o perceiveLoop do EIS a consumir o proximo passo
// actionID repetido (mesmo passo reprocessado pela ponte EIS): ignora,
// garantindo UMA acao por passo.
+actionID(_) <- true.


/* ===================================================================== */
/* PASSO 1: MEMORIA DE MAPA (RELATIVO -> ABSOLUTO) + PUBLICACAO           */
/* ===================================================================== */

/*
 * Converte cada percepcao relativa do step em coordenada absoluta no frame
 * PROPRIO (somando a posicao atual) e guarda como crenca mem_*(...). A
 * publicacao no quadro NAO e feita aqui: ela ocorre em !publicar_mapa_ref,
 * ja re-projetada para o frame de referencia (passo 2), de modo que os
 * mapas dos varios exploradores se fundam.
 *
 * NOMES DE PERCEPT (MAPC 2022, confirmados em docs/eismassim.md):
 *   dispenser -> thing(X,Y,dispenser,Tipo)
 *   goal zone -> goalZone(X,Y)
 *   role zone -> roleZone(X,Y)
 * (NAO existe taskboard nem goal(X,Y) no 2022 - isso era do cenario 2021.)
 */
+!registrar_descobertas : flag_mapear & posicao(PX, PY) <-
    for ( thing(RX, RY, dispenser, Tipo) ) {
        AX = PX + RX; AY = PY + RY;
        if ( not mem_dispenser(AX, AY, Tipo) ) { +mem_dispenser(AX, AY, Tipo); }
    }
    for ( goalZone(RX, RY) ) {
        AX = PX + RX; AY = PY + RY;
        if ( not mem_goalzone(AX, AY) ) { +mem_goalzone(AX, AY); }
    }
    for ( roleZone(RX, RY) ) {
        AX = PX + RX; AY = PY + RY;
        if ( not mem_rolezone(AX, AY) ) { +mem_rolezone(AX, AY); }
    }
    !publicar_mapa_ref.
// flag_mapear desligada (ou sem posicao ainda): nao faz nada.
+!registrar_descobertas <- true.

/*
 * Publica no QuadroEquipe (no frame de REFERENCIA) as descobertas mem_ ainda
 * nao publicadas. So roda quando offset_ref ja e conhecido; converte cada
 * coordenada do frame proprio para o de referencia somando offset_ref. Marca
 * com pub_* para nao republicar. Quando dois exploradores publicam o mesmo
 * ponto fisico, sai a MESMA coordenada de referencia -> a dedup do
 * QuadroEquipe funde os mapas.
 */
+!publicar_mapa_ref : offset_ref(RDX, RDY) <-
    for ( mem_dispenser(AX, AY, Tipo) & not pub_dispenser(AX, AY, Tipo) ) {
        registrar_dispenser(AX + RDX, AY + RDY, Tipo);
        +pub_dispenser(AX, AY, Tipo);
    }
    for ( mem_goalzone(AX, AY) & not pub_goalzone(AX, AY) ) {
        registrar_goal(AX + RDX, AY + RDY);
        +pub_goalzone(AX, AY);
    }
    for ( mem_rolezone(AX, AY) & not pub_rolezone(AX, AY) ) {
        registrar_rolezone(AX + RDX, AY + RDY);
        +pub_rolezone(AX, AY);
    }.
// offset_ref ainda desconhecido: mantem em mem_ e tenta de novo nos proximos passos.
+!publicar_mapa_ref <- true.


/*
 * PASSO 2 (identificacao de companheiros por posicao-espelho) agora e
 * compartilhado: os planos !identificar_companheiros, !publicar_posicao e os
 * handlers de mensagem (avistei_colega/seu_offset) ficam em agente_base.asl,
 * pois tanto exploradores quanto o coordenador participam do alinhamento.
 */


/* ===================================================================== */
/* ESCOLHA DE ACAO: ESCAPE POR clear + RANDOM WALK                        */
/* ===================================================================== */

/*
 * Regras auxiliares para decidir o movimento.
 *
 * celula_bloqueada(DX,DY): a celula relativa (DX,DY) tem algo que impede
 *   o agente de entrar (obstaculo, bloco ou outra entidade).
 * direcao_livre(D): existe uma direcao cardinal D cuja celula esta livre.
 * obstaculo_adjacente(DX,DY): ha um obstaculo numa celula cardinal vizinha.
 * energia_ok: energia atual >= energia_minima_seguranca (de agente_base).
 */
celula_bloqueada(DX,DY) :- thing(DX,DY,obstacle,_).
celula_bloqueada(DX,DY) :- thing(DX,DY,block,_).
celula_bloqueada(DX,DY) :- thing(DX,DY,entity,_).

direcao_livre(D)        :- delta(D,DX,DY) & not celula_bloqueada(DX,DY).

obstaculo_adjacente(DX,DY) :- delta(_,DX,DY) & thing(DX,DY,obstacle,_).

energia_ok :- energy(E) & energia_minima_seguranca(Min) & E >= Min.

/*
 * ALVOS CONHECIDOS no FRAME PROPRIO. Refinamento: alem do que o agente viu
 * pessoalmente (mem_*), usa o MAPA COMPARTILHADO (frame de referencia,
 * dispenser_descoberto/goal_descoberta/rolezone_descoberta) convertendo para
 * o frame proprio via offset_ref. Assim um worker pode ir ao dispenser que
 * OUTRO agente achou.
 *   ponto_proprio = ponto_ref - offset_ref
 */
disp_conhecido(T, X, Y) :- mem_dispenser(X, Y, T).
disp_conhecido(T, X, Y) :- dispenser_descoberto(RX, RY, DT) & mesmo_tipo(T, DT)
                           & offset_ref(RDX, RDY) & X = RX - RDX & Y = RY - RDY.
// tipos iguais, robusto a ATOMO (task) vs STRING (mapa compartilhado via Java)
mesmo_tipo(T, T).
mesmo_tipo(T, DT) :- .term2string(T, DT).

// igualdade de tipo SIMETRICA: converte AMBOS os lados a string e compara.
// Necessaria porque o tipo da tarefa_alvo chega como STRING "b1" (veio do
// coordenador via CArtAgO), mas o tipo no percept thing(...) e o ATOMO b1.
// Sem isso, a unificacao crua "b1" \= b1 e a visao nunca casa o dispenser.
tipo_igual(A, B) :- .term2string(A, S) & .term2string(B, S).

/*
 * ALVOS VISIVEIS (na visao atual, em coords RELATIVAS). Navegar por estes e
 * robusto ao grid TOROIDAL - a percepcao relativa e sempre o caminho curto
 * real, ao contrario das coordenadas absolutas gravadas (que divergem no toro).
 * (0,0) e a propria celula, entao excluimos.
 */
rolezone_visivel(RX, RY)    :- roleZone(RX, RY) & (RX \== 0 | RY \== 0).
goalzone_visivel(GX, GY)    :- goalZone(GX, GY) & (GX \== 0 | GY \== 0).
dispenser_visivel(T, DX, DY) :- thing(DX, DY, dispenser, DT) & tipo_igual(T, DT).

/*
 * Move UM passo rumo a um alvo dado em coordenada RELATIVA (RX,RY) a partir de
 * mim (que sou (0,0)). Reusa o dir_gulosa: o "delta ate o alvo" e o proprio
 * (RX,RY). Sem saida livre -> explora.
 */
+!mover_rel(RX, RY, move(Dir)) : direcao_livre(_) <- !dir_gulosa(RX, RY, Dir).
+!mover_rel(_, _, Acao) <- !explorar(Acao).

goalzone_conhecida(X, Y) :- mem_goalzone(X, Y).
goalzone_conhecida(X, Y) :- goal_descoberta(RX, RY) & offset_ref(RDX, RDY)
                            & X = RX - RDX & Y = RY - RDY.

rolezone_conhecida(X, Y) :- mem_rolezone(X, Y).
rolezone_conhecida(X, Y) :- rolezone_descoberta(RX, RY) & offset_ref(RDX, RDY)
                            & X = RX - RDX & Y = RY - RDY.

/*
 * ANTI-OSCILACAO: a direcao D leva de volta a celula de onde acabei de vir?
 * livre_ok(D): direcao livre que NAO volta atras (preferida na navegacao).
 */
volta_atras(D) :- delta(D, DX, DY) & posicao(X, Y) & pos_anterior(PX, PY)
                  & PX == X + DX & PY == Y + DY.
livre_ok(D)    :- direcao_livre(D) & not volta_atras(D).
// livre_novo(D): livre, nao volta atras E leva a uma celula AINDA NAO visitada.
// Vies de cobertura - escapa de bolsoes rumo a area nova (em vez de quicar).
livre_novo(D)  :- livre_ok(D) & delta(D, DX, DY) & posicao(X, Y)
                  & TX = X + DX & TY = Y + DY & not visitado(TX, TY).

/*
 * ALVO MAIS PROXIMO (Manhattan) de cada tipo, no frame proprio. Reduz passos
 * desperdiçados em relacao a pegar um alvo arbitrario. So sao chamados quando
 * o respectivo *_conhecida/_conhecido ja vale (a lista nunca e vazia).
 */
+!alvo_rolezone_proximo(X, Y) : posicao(PX, PY) <-
    .findall(d(D, RX, RY),
             (rolezone_conhecida(RX, RY) & D = math.abs(RX-PX) + math.abs(RY-PY)), L);
    .min(L, d(_, X, Y)).
+!alvo_disp_proximo(T, X, Y) : posicao(PX, PY) <-
    .findall(d(D, DX, DY),
             (disp_conhecido(T, DX, DY) & D = math.abs(DX-PX) + math.abs(DY-PY)), L);
    .min(L, d(_, X, Y)).
+!alvo_goalzone_proximo(X, Y) : posicao(PX, PY) <-
    .findall(d(D, GX, GY),
             (goalzone_conhecida(GX, GY) & D = math.abs(GX-PX) + math.abs(GY-PY)), L);
    .min(L, d(_, X, Y)).

/*
 * ESCOLHA DE ACAO (prioridade):
 *   1) Se sou worker e ha task-alvo -> logica do worker (acao_worker).
 *   2) Caso contrario -> exploracao dirigida (que tambem cava obstaculos
 *      se estiver encurralado).
 */
+!escolher_acao(Acao) : sou_multi & tarefa_multi(N,_,_,_,_) <-
    !acao_multi(N, Acao).
+!escolher_acao(Acao) : sou_worker & tarefa_alvo(N,QX,QY,_) & tipo_alvo(T) <-
    !acao_worker(N, QX, QY, T, Acao).
+!escolher_acao(Acao) <-
    !explorar(Acao).

/* --------------------------------------------------------------------- */
/* EXPLORACAO DIRIGIDA (cobertura/rendezvous, com anti-oscilacao)        */
/* --------------------------------------------------------------------- */
/*
 * EXPLORACAO POR COBERTURA (varredura serpentina / "lawnmower").
 *
 * Cada explorador segue uma direcao PRIMARIA por cob_leg passos, da UM passo
 * PERPENDICULAR, reverte a primaria e repete - varrendo faixas de forma
 * sistematica (cobre muito mais que random walk, entao os workers topam com
 * dispensers/zonas com confiabilidade). Robusto ao grid TOROIDAL: conta passos
 * RELATIVOS, nao usa coordenadas absolutas. Os dois exploradores comecam com
 * orientacoes diferentes para cobrir mais. Obstaculos: vira/desvia.
 */
cob_leg(20).   // perna longa: varre faixas largas (melhor cobertura)   // comprimento da perna da serpentina

// Init preguicoso do estado de cobertura (na 1a vez que explora).
+!explorar(Acao) : not cob_dir(_) <-
    .my_name(Eu);  !init_cobertura(Eu);  !explorar(Acao).
+!init_cobertura(explorador1) <- +cob_dir(e); +cob_perp(s); ?cob_leg(N); +cob_passos(N).
+!init_cobertura(explorador2) <- +cob_dir(s); +cob_perp(e); ?cob_leg(N); +cob_passos(N).
+!init_cobertura(_)           <- +cob_dir(n); +cob_perp(e); ?cob_leg(N); +cob_passos(N).

// PRIORIDADE DE COBERTURA (frontier-com-momentum), antes da serpentina rigida:
// (1) se o rumo atual leva a area NOVA, segue reto (linhas longas, boa cobertura).
+!explorar(move(D)) : cob_dir(D) & livre_novo(D) <-
    ?cob_leg(N);  -+cob_passos(N).
// (2) rumo atual nao leva a area nova, mas ha area nova adjacente -> vira pra la
// e recompromete o rumo. Escapa de cavidades sem quicar (bug observado ao vivo:
// a serpentina seguia o rumo para dentro de um buraco visitado de 2 celulas).
+!explorar(move(Dir)) : livre_novo(_) <-
    !dir_novo_aleatoria(Dir);  -+cob_dir(Dir);  ?cob_leg(N);  -+cob_passos(N).
// (2b) ESCAPE-BY-CLEAR: nao ha area nova ANDAVEL (livre_novo vazio), mas ha
// obstaculo adjacente e energia -> CAVA para abrir frente nova, em vez de vagar/
// circular pelo territorio ja explorado (loop 2x3 e bolsao selado observados ao
// vivo). Cavar tem prioridade sobre andar-no-explorado, nao sobre andar-no-novo.
+!explorar(clear(DX,DY)) : not livre_novo(_) & energia_ok & obstaculo_adjacente(DX,DY) <-
    .my_name(Eu);
    .print("[", Eu, "] sem frente nova; cavando (", DX, ",", DY, ") p/ abrir caminho").
// (3) sem area nova adjacente: cai na serpentina/desvio (varre/sai do explorado).
// Segue a direcao primaria enquanto LIVRE E SEM VOLTAR ATRAS (livre_ok) e ainda
// ha passos na perna. Usar livre_ok (nao direcao_livre) impede seguir o rumo de
// volta para dentro de um beco ja visitado (oscilacao residual observada ao vivo).
+!explorar(move(D)) : cob_dir(D) & cob_passos(N) & N > 0 & livre_ok(D) <-
    -+cob_passos(N-1).
// Fim da perna (N=0) OU primaria bloqueada -> passo PERPENDICULAR (se livre),
// reverte a primaria e reinicia a contagem da perna.
+!explorar(move(P)) : cob_perp(P) & direcao_livre(P) & cob_dir(D)
                      & (cob_passos(0) | not direcao_livre(D)) <-
    !reverter_dir(D);  ?cob_leg(N);  -+cob_passos(N).
// Hora de virar, mas a perpendicular NORMAL esta bloqueada: vira pela perpendicular
// OPOSTA (mantem a varredura sistematica, so deriva para o outro lado).
+!explorar(move(Pop)) : cob_perp(P) & oposta(P, Pop) & direcao_livre(Pop) & cob_dir(D)
                        & (cob_passos(0) | not direcao_livre(D)) <-
    !reverter_dir(D);  ?cob_leg(N);  -+cob_passos(N).
// Desvio nivel 1: ha direcao livre rumo a celula NAO-VISITADA -> vai pra la
// (escapa de bolsoes/oscilacao indo para area nova) e recompromete o rumo.
+!explorar(move(Dir)) : livre_novo(_) <-
    !dir_novo_aleatoria(Dir);
    -+cob_dir(Dir);  ?cob_leg(N);  -+cob_passos(N).
// Desvio nivel 2: sem celula nova, mas ha livre que NAO volta atras. Evita o
// "sobe-desce uma casa" em corredores (oscilacao observada ao vivo) e RECOMPROMETE
// o rumo - comeca uma perna nova na direcao livre, em vez de insistir num rumo bloqueado.
+!explorar(move(Dir)) : livre_ok(_) <-
    !dir_livre_ok_aleatoria(Dir);
    -+cob_dir(Dir);  ?cob_leg(N);  -+cob_passos(N).
// Beco sem saida (sem obstaculo p/ cavar ou sem energia): a unica direcao livre e
// voltar atras -> aceita (senao trava) e recompromete o rumo para sair.
+!explorar(move(Dir)) : direcao_livre(_) <-
    !dir_livre_aleatoria(Dir);
    -+cob_dir(Dir);  ?cob_leg(N);  -+cob_passos(N).

+!reverter_dir(e) <- -+cob_dir(w).
+!reverter_dir(w) <- -+cob_dir(e).
+!reverter_dir(s) <- -+cob_dir(n).
+!reverter_dir(n) <- -+cob_dir(s).
oposta(e, w).  oposta(w, e).  oposta(s, n).  oposta(n, s).
+!explorar(skip) <- true.

+!dir_novo_aleatoria(Dir) <-
    .findall(D, livre_novo(D), L);
    .length(L, N);  .random(R);  I = math.floor(R * N);  .nth(I, L, Dir).
+!dir_livre_ok_aleatoria(Dir) <-
    .findall(D, livre_ok(D), L);
    .length(L, N);  .random(R);  I = math.floor(R * N);  .nth(I, L, Dir).
+!dir_livre_aleatoria(Dir) <-
    .findall(D, direcao_livre(D), L);
    .length(L, N);  .random(R);  I = math.floor(R * N);  .nth(I, L, Dir).

/* --------------------------------------------------------------------- */
/* NAVEGACAO GULOSA rumo a um alvo (TX,TY) no frame proprio              */
/* --------------------------------------------------------------------- */
// ha alguma saida -> escolhe direcao (dir_gulosa sempre acha uma); senao explora.
+!mover_rumo(TX, TY, move(Dir)) : direcao_livre(_) & posicao(X, Y) <-
    DX = TX - X;  DY = TY - Y;
    !dir_gulosa(DX, DY, Dir).
+!mover_rumo(_, _, Acao) <-
    !explorar(Acao).

// 1) eixo dominante, livre e sem voltar atras
+!dir_gulosa(DX, DY, e) : DX > 0 & math.abs(DX) >= math.abs(DY) & livre_ok(e) <- true.
+!dir_gulosa(DX, DY, w) : DX < 0 & math.abs(DX) >= math.abs(DY) & livre_ok(w) <- true.
+!dir_gulosa(DX, DY, s) : DY > 0 & math.abs(DY) >  math.abs(DX) & livre_ok(s) <- true.
+!dir_gulosa(DX, DY, n) : DY < 0 & math.abs(DY) >  math.abs(DX) & livre_ok(n) <- true.
// 2) a outra direcao util, livre e sem voltar atras
+!dir_gulosa(DX, _,  e) : DX > 0 & livre_ok(e) <- true.
+!dir_gulosa(DX, _,  w) : DX < 0 & livre_ok(w) <- true.
+!dir_gulosa(_,  DY, s) : DY > 0 & livre_ok(s) <- true.
+!dir_gulosa(_,  DY, n) : DY < 0 & livre_ok(n) <- true.
// 3) qualquer direcao livre sem voltar atras
+!dir_gulosa(_, _, D) : livre_ok(D) <- true.
// 4) ultima opcao: qualquer direcao livre (pode voltar atras) - garante saida
+!dir_gulosa(_, _, D) : direcao_livre(D) <- true.


/* ===================================================================== */
/* PASSO 3: WORKER - BUSCAR BLOCO, LEVAR A GOAL ZONE E SUBMETER           */
/* ===================================================================== */

/*
 * Quando o coordenador anuncia tarefa_alvo(N,QX,QY,T) no QuadroEquipe, o
 * explorador se promove a worker (sou_worker). Daí em diante, acao_worker
 * conduz a maquina de estados a cada passo.
 *
 * Modelo MAPC 2022 (sem accept/taskboard): escolher task -> juntar bloco
 * (request+attach num dispenser) -> levar a uma goal zone -> submit.
 *
 * LIMITACOES conhecidas (single-block, papeis padrao):
 *  - so tratamos tasks de 1 bloco com requisito em celula cardinal
 *    adjacente (|QX|+|QY|=1), pois o worker NAO tem a acao rotate.
 *  - para o bloco cair na posicao (QX,QY) exigida, aproximamos o dispenser
 *    pelo lado certo (ficar na celula dispenser-(QX,QY)) e pedir/anexar
 *    na direcao (QX,QY).
 *  - role default nao faz request/attach/submit; por isso e preciso achar
 *    um role zone e adoptar "worker" antes.
 */
@reagir_tarefa_alvo
+tarefa_alvo(N, QX, QY, T) : flag_virar_worker & not sou_worker <-
    .my_name(Eu);
    // T chega como STRING "b1" (veio do coordenador via CArtAgO). Convertemos
    // ao ATOMO b1 (parse via .term2string com 1o arg livre) e guardamos em
    // tipo_alvo, para casar por unificacao pura com thing(...,dispenser,b1).
    .term2string(Tatom, T);  -+tipo_alvo(Tatom);
    .print("[WORKER] ", Eu, " assumiu task ", N, " (bloco ", Tatom, " em ", QX, ",", QY, ")");
    +sou_worker.

// mapeia um deslocamento cardinal (QX,QY) para a direcao correspondente
dir_de_delta(QX, QY, Dir) :- delta(Dir, QX, QY).

// quantos passos esperar o bloco aparecer apos um request antes de desistir
// (evita deadlock se o request falhar no servidor e o bloco nunca vier)
max_espera_bloco(5).

/* ---- INSTRUMENTACAO DA COLETA (so imprime quando ja sou worker) ----
 * Mostra, a cada passo, o estado da maquina de coleta para diagnosticar
 * ONDE a fase B/C trava: papel adotado, task-alvo, dispensers do tipo
 * VISIVEIS (e onde), zonas visiveis, pedido pendente, espera e carga.   */
+!diag_worker : flag_debug & sou_worker & tarefa_alvo(N, QX, QY, _) & tipo_alvo(T) <-
    .my_name(Eu);
    .findall(d(DX,DY), dispenser_visivel(T, DX, DY), DispV);
    .findall(k(KX,KY), disp_conhecido(T, KX, KY),    DispK);
    .findall(x, rolezone_visivel(_,_),   RZv);  .length(RZv, NRZv);
    .findall(x, goalzone_visivel(_,_),   GZv);  .length(GZv, NGZv);
    .findall(x, rolezone_conhecida(_,_), RZk);  .length(RZk, NRZk);
    .findall(x, goalzone_conhecida(_,_), GZk);  .length(GZk, NGZk);
    .findall(p(P),   role(P),        Papeis);
    .findall(pb(PD), pedi_bloco(PD),  PB);
    .findall(ew(K),  espera_bloco(K), Esp);
    .findall(cg(CT), carregando(CT),  Carga);
    .print("[DIAGW] ", Eu, " papeis=", Papeis, " task=", N,
           " req=(", QX, ",", QY, ") T=", T,
           " | disp_vis=", DispV, " disp_conh=", DispK,
           " | rz_vis=", NRZv, " rz_conh=", NRZk, " gz_vis=", NGZv, " gz_conh=", NGZk,
           " | pedi=", PB, " espera=", Esp, " carrega=", Carga).
+!diag_worker <- true.

/* ---- DIAGNOSTICO DE EXPLORACAO (gateado por flag_debug) ----
 * Por passo, na fase de exploracao: posicao, resultado da ultima acao,
 * direcoes livres / livres-sem-backtrack / livres-para-area-nova e a acao
 * escolhida. Serve para diagnosticar oscilacao e moves que falham.        */
+!diag_explora(Acao) : flag_debug & not sou_worker & posicao(X, Y) <-
    .findall(la(A,R), (lastAction(A) & lastActionResult(R)), LAR);
    .findall(F,  direcao_livre(F), Livres);
    .findall(O,  livre_ok(O),      OkL);
    .findall(Nv, livre_novo(Nv),   NovoL);
    .findall(ob(OX,OY), obstaculo_adjacente(OX,OY), Obst);
    .findall(en, energia_ok, EnOk);
    .my_name(Eu);
    .print("[DIAGE] ", Eu, " pos(", X, ",", Y, ") ", LAR, " acao=", Acao,
           " livres=", Livres, " ok=", OkL, " novo=", NovoL,
           " obst=", Obst, " energia_ok=", EnOk).
+!diag_explora(_) <- true.

/* ---- RESET POS-SUBMIT ----------------------------------------------------
 * Apos um submit BEM-SUCEDIDO (lastActionResult success no passo anterior), a
 * tarefa esta concluida: liberamos o estado de coleta (carregando/pedido) e o
 * papel social de worker (sou_worker/tipo_alvo), para o agente voltar a explorar
 * e poder assumir uma NOVA tarefa quando o coordenador anunciar outra. Sem isto,
 * o worker fica preso reenviando submit na mesma goal zone.                    */
+!reset_pos_submit
    : sou_worker & carregando(_) & lastAction(submit) & lastActionResult(success) <-
    .my_name(Eu);
    .print("[WORKER] ", Eu, " task concluida (submit ok) - liberando estado p/ nova tarefa");
    .abolish(carregando(_));
    .abolish(pedi_bloco(_));
    .abolish(espera_bloco(_));
    .abolish(tipo_alvo(_));
    -sou_worker.
+!reset_pos_submit <- true.

/* ---- FASE A: adotar o papel de cenario "worker" (precisa de role zone) ---- */
// estou sobre um role zone -> adopt(worker)
+!acao_worker(_, _, _, _, adopt(worker)) : not role(worker) & roleZone(0,0) <- true.
// VEJO um role zone -> navego por VISAO (relativo, robusto ao toro)
+!acao_worker(_, _, _, _, Acao) : not role(worker) & rolezone_visivel(RX, RY) <-
    !mover_rel(RX, RY, Acao).
// nao vejo, mas CONHECO um role zone (mapa) -> rumo ao mais proximo ate avista-lo;
// ao entrar na visao (raio 5), o plano acima (por VISAO) assume a aproximacao final.
+!acao_worker(_, _, _, _, Acao) : not role(worker) & rolezone_conhecida(_, _) <-
    !alvo_rolezone_proximo(TX, TY);  !mover_rumo(TX, TY, Acao).
// nem vejo nem conheco um role zone -> exploro ate um entrar na visao
+!acao_worker(_, _, _, _, Acao) : not role(worker) <-
    !explorar(Acao).

/* ---- FASE B: sou worker, ainda sem bloco -> buscar/anexar ---- */
// o dispenser do tipo esta exatamente na direcao requerida (QX,QY) -> request
+!acao_worker(_, QX, QY, T, request(Dir))
    : role(worker) & not carregando(_) & not pedi_bloco(_)
      & dir_de_delta(QX, QY, Dir) & thing(QX, QY, dispenser, DT) & tipo_igual(T, DT)
    <- +pedi_bloco(Dir);  +espera_bloco(0).
// pedi e o bloco apareceu em (QX,QY) -> attach
+!acao_worker(_, QX, QY, T, attach(Dir))
    : role(worker) & not carregando(_) & pedi_bloco(Dir) & thing(QX, QY, block, _)
    <- -pedi_bloco(Dir); .abolish(espera_bloco(_)); +carregando(T);
       .my_name(Eu); .print("[WORKER] ", Eu, " anexou bloco ", T, " em (", QX, ",", QY, ")").
// pedi mas o bloco ainda nao apareceu, dentro do limite -> conta e espera
+!acao_worker(_, _, _, _, skip)
    : role(worker) & not carregando(_) & pedi_bloco(_)
      & espera_bloco(K) & max_espera_bloco(Max) & K < Max
    <- Kp = K + 1;  -+espera_bloco(Kp).
// estourou o limite de espera -> desiste do pedido e volta a buscar
// (destrava o deadlock: request pode ter falhado no servidor)
+!acao_worker(N, QX, QY, T, Acao)
    : role(worker) & not carregando(_) & pedi_bloco(_)
      & espera_bloco(K) & max_espera_bloco(Max) & K >= Max
    <- .my_name(Eu);
       .print("[WORKER] ", Eu, " timeout esperando bloco (", K, " passos) - desiste do pedido e retoma busca");
       .abolish(pedi_bloco(_));  .abolish(espera_bloco(_));
       !acao_worker(N, QX, QY, T, Acao).
// VEJO um dispenser do tipo -> me posiciono (por VISAO) na celula que poe o
// dispenser em (QX,QY): se ele esta em (DX,DY) relativo, ando rumo a (DX-QX,DY-QY).
+!acao_worker(_, QX, QY, T, Acao)
    : role(worker) & not carregando(_) & not pedi_bloco(_) & dispenser_visivel(T, DX, DY)
    <- RX = DX - QX;  RY = DY - QY;
       !mover_rel(RX, RY, Acao).
// nao vejo, mas CONHECO um dispenser do tipo (mapa) -> rumo ao mais proximo ate
// avista-lo; ao entrar na visao, o plano por VISAO acima faz o posicionamento fino.
+!acao_worker(_, _, _, T, Acao)
    : role(worker) & not carregando(_) & not pedi_bloco(_) & disp_conhecido(T, _, _)
    <- !alvo_disp_proximo(T, TX, TY);  !mover_rumo(TX, TY, Acao).
// nem vejo nem conheco um dispenser do tipo -> exploro ate um entrar na visao
+!acao_worker(_, _, _, _, Acao) : role(worker) & not carregando(_) <-
    !explorar(Acao).

/* ---- FASE C: sou worker, com bloco -> levar a goal zone e submeter ---- */
// estou numa goal zone -> submit
+!acao_worker(N, _, _, _, submit(N))
    : role(worker) & carregando(_) & goalZone(0,0) & flag_submeter
    <- .my_name(Eu); .print("[WORKER] ", Eu, " em goal zone - submetendo ", N).
// VEJO uma goal zone -> navego por VISAO (relativo, robusto ao toro)
+!acao_worker(_, _, _, _, Acao) : role(worker) & carregando(_) & goalzone_visivel(GX, GY) <-
    !mover_rel(GX, GY, Acao).
// nao vejo, mas CONHECO uma goal zone (mapa) -> rumo a mais proxima ate avista-la
+!acao_worker(_, _, _, _, Acao) : role(worker) & carregando(_) & goalzone_conhecida(_, _) <-
    !alvo_goalzone_proximo(TX, TY);  !mover_rumo(TX, TY, Acao).
// nem vejo nem conheco uma goal zone -> exploro ate uma entrar na visao
+!acao_worker(_, _, _, _, Acao) : role(worker) & carregando(_) <-
    !explorar(Acao).

// fallback geral
+!acao_worker(_, _, _, _, skip) <- true.

/* ===================================================================== */
/* PASSO 5: WORKER MULTI-BLOCO (2 blocos via connect cooperativo)         */
/* ===================================================================== */
/*
 * Quando o coordenador anuncia tarefa_multi(N,Sub,Helper,GZx,GZy), os dois
 * exploradores assumem papeis (submitter/helper). A task tem 2 reqs: a ANCORA
 * (cardinal, adjacente ao submitter) e o SEGUNDO bloco (adjacente a ancora).
 *
 * Geometria (helper anexa SEU bloco ao SUL, em (0,1)):
 *   - submitter S anexa a ancora em (AX,AY); fica numa goal zone, parado.
 *   - helper posiciona-se em P_h = P_s + (BX, BY-1) -> seu bloco (P_h+(0,1))
 *     cai em P_s+(BX,BY), adjacente a ancora.
 *   - barreira pronto_connect: cada um so dispara connect quando ve o outro
 *     pronto -> connect no MESMO step. S: connect(Helper,AX,AY). H: connect(Sub,0,1).
 *   - apos connect: helper detach (bloco fica preso ao S via ancora); S submit.
 * Alinhamento via posicao compartilhada: Sub=explorador1=frame de referencia
 * (offset_ref(0,0)), entao pos_agente(Sub) ja esta em coords de referencia.
 */
@reagir_multi_sub
+tarefa_multi(N, Sub, _, _, _)
    : flag_virar_worker & not sou_multi & not sou_worker
      & .my_name(Eu) & .term2string(Eu, EuS) & EuS == Sub <-
    +papel_multi(submitter);  +sou_multi;
    .print("[MULTI] ", Eu, " = SUBMITTER da task ", N).
@reagir_multi_helper
+tarefa_multi(N, _, Helper, _, _)
    : flag_virar_worker & not sou_multi & not sou_worker
      & .my_name(Eu) & .term2string(Eu, EuS) & EuS == Helper <-
    +papel_multi(helper);  +sou_multi;
    .print("[MULTI] ", Eu, " = HELPER da task ", N).

// req ANCORA (cardinal, adjacente) e SEGUNDO (nao-cardinal) da task multi.
anchor_req(N, QX, QY, T)  :- task(N,_,_,Reqs) & .member(req(QX,QY,T), Reqs)
                             & (math.abs(QX) + math.abs(QY)) == 1.
segundo_req(N, QX, QY, T) :- task(N,_,_,Reqs) & .member(req(QX,QY,T), Reqs)
                             & (math.abs(QX) + math.abs(QY)) \== 1.

// alvo do helper (frame proprio): P_s + (BX, BY-1). pos_agente(Sub) em ref
// (Sub=explorador1, offset_ref(0,0)); helper converte ref->proprio (- offset_ref).
alvo_helper(N, TX, TY) :- tarefa_multi(N, Sub, _, _, _) & segundo_req(N, BX, BY, _)
                          & pos_agente(Sub, SX, SY) & offset_ref(ORDX, ORDY)
                          & TX = SX - ORDX + BX & TY = SY - ORDY + BY - 1.

// dispenser do tipo T VISIVEL mais proximo (Manhattan, coords ja relativas).
// Alvo estavel: evita perseguir o "primeiro arbitrario" quando ha muitos do
// mesmo tipo na visao (caso blockTypes unico).
+!alvo_disp_visivel_proximo(T, DX, DY) <-
    .findall(d(Dist, X, Y), (dispenser_visivel(T, X, Y) & Dist = math.abs(X) + math.abs(Y)), L);
    .min(L, d(_, DX, DY)).

/* NAVEGACAO GULOSA PRECISA (rumo a (RX,RY), PERMITE recuar). Para POSICIONAR no
 * dispenser e preciso poder recuar 1 celula para encaixa-lo no offset exato; o
 * anti-backtrack de dir_gulosa faz o agente derivar no campo denso. Aqui usamos
 * direcao_livre (sem livre_ok), garantindo convergencia ao alvo de curto alcance. */
+!mover_preciso(RX, RY, move(Dir)) : direcao_livre(_) <- !dir_greedy(RX, RY, Dir).
+!mover_preciso(_, _, Acao) <- !explorar(Acao).
+!dir_greedy(DX, DY, e) : DX > 0 & math.abs(DX) >= math.abs(DY) & direcao_livre(e) <- true.
+!dir_greedy(DX, DY, w) : DX < 0 & math.abs(DX) >= math.abs(DY) & direcao_livre(w) <- true.
+!dir_greedy(DX, DY, s) : DY > 0 & math.abs(DY) >  math.abs(DX) & direcao_livre(s) <- true.
+!dir_greedy(DX, DY, n) : DY < 0 & math.abs(DY) >  math.abs(DX) & direcao_livre(n) <- true.
+!dir_greedy(DX, _,  e) : DX > 0 & direcao_livre(e) <- true.
+!dir_greedy(DX, _,  w) : DX < 0 & direcao_livre(w) <- true.
+!dir_greedy(_,  DY, s) : DY > 0 & direcao_livre(s) <- true.
+!dir_greedy(_,  DY, n) : DY < 0 & direcao_livre(n) <- true.
+!dir_greedy(_,  _,  D) : direcao_livre(D) <- true.

/* ---- POSICIONAR NO DISPENSER com COMPROMISSO (fix da deriva) ----
 * Em campo denso, re-mirar no dispenser visivel a cada passo faz o agente
 * persegui-lo e DERIVAR sem encaixar. Aqui o agente COMPROMETE-SE com UM
 * dispenser (guarda a posicao ABSOLUTA propria dele em disp_alvo) e navega ate
 * a celula que o poe no offset (QX,QY); como o alvo e FIXO, converge. O alvo e
 * limpo no request/attach (e na salvaguarda de alvo invalido).               */
// (a) ja tenho alvo: navego ate a celula (disp - offset). Se ja cheguei mas o
//     dispenser nao esta no offset (alvo invalido), descarto e re-comprometo.
+!posicionar_dispenser(_, QX, QY, Acao)
    : disp_alvo(DAX, DAY) & posicao(PX, PY)
      & DAX - QX == PX & DAY - QY == PY & not thing(QX, QY, dispenser, _)
    <- .abolish(disp_alvo(_,_));  !explorar(Acao).
+!posicionar_dispenser(_, QX, QY, Acao)
    : disp_alvo(DAX, DAY) & posicao(PX, PY)
    <- RX = (DAX - QX) - PX;  RY = (DAY - QY) - PY;  !mover_preciso(RX, RY, Acao).
// (b) sem alvo, mas vejo dispenser do tipo: comprometo com o MAIS PROXIMO
//     (guardo sua posicao absoluta propria) e ja navego neste passo.
+!posicionar_dispenser(T, QX, QY, Acao)
    : not disp_alvo(_,_) & dispenser_visivel(T, _, _) & posicao(PX, PY)
    <- !alvo_disp_visivel_proximo(T, DX, DY);
       +disp_alvo(PX + DX, PY + DY);
       RX = ((PX + DX) - QX) - PX;  RY = ((PY + DY) - QY) - PY;
       !mover_preciso(RX, RY, Acao).
// (c) sem alvo e sem dispenser do tipo a vista -> exploro ate achar um.
+!posicionar_dispenser(_, _, _, Acao) <- !explorar(Acao).

/* ---- adotar o papel de cenario "worker" (compartilhado) ---- */
+!adotar_worker(adopt(worker)) : roleZone(0,0) <- true.
+!adotar_worker(Acao) : rolezone_visivel(RX, RY) <- !mover_rel(RX, RY, Acao).
+!adotar_worker(Acao) : rolezone_conhecida(_, _) <-
    !alvo_rolezone_proximo(TX, TY);  !mover_rumo(TX, TY, Acao).
+!adotar_worker(Acao) <- !explorar(Acao).

// SALVAGUARDA: a task comprometida nao esta mais ativa (expirou) -> larga o papel
// multi e volta a explorar; reengaja quando o coordenador reanunciar uma task valida.
+!acao_multi(N, Acao) : sou_multi & not task(N,_,_,_) <-
    .my_name(Eu); .print("[MULTI] ", Eu, " task ", N, " expirou - liberando papel multi");
    .abolish(papel_multi(_)); .abolish(disp_alvo(_,_));
    .abolish(pedi_bloco(_)); .abolish(espera_bloco(_)); -sou_multi;
    !explorar(Acao).

/* ====================== SUBMITTER ====================== */
// Fase A: adotar worker
+!acao_multi(_, Acao) : papel_multi(submitter) & not role(worker) <- !adotar_worker(Acao).
// Fase B: buscar a ANCORA e anexar em (AX,AY)
+!acao_multi(N, request(Dir))
    : papel_multi(submitter) & role(worker) & not carregando(_) & not pedi_bloco(_)
      & anchor_req(N,AX,AY,AT) & dir_de_delta(AX,AY,Dir) & thing(AX,AY,dispenser,DT) & tipo_igual(AT,DT)
    <- +pedi_bloco(Dir);  +espera_bloco(0);  .abolish(disp_alvo(_,_)).
+!acao_multi(N, attach(Dir))
    : papel_multi(submitter) & role(worker) & not carregando(_) & pedi_bloco(Dir)
      & anchor_req(N,AX,AY,_) & thing(AX,AY,block,_)
    <- -pedi_bloco(Dir); .abolish(espera_bloco(_)); .abolish(disp_alvo(_,_)); +carregando(ancora);
       .my_name(Eu); .print("[MULTI] ", Eu, " (sub) anexou ancora em (",AX,",",AY,")").
+!acao_multi(_, skip)
    : papel_multi(submitter) & role(worker) & not carregando(_) & pedi_bloco(_)
      & espera_bloco(K) & max_espera_bloco(Max) & K < Max
    <- Kp = K + 1;  -+espera_bloco(Kp).
+!acao_multi(N, Acao)
    : papel_multi(submitter) & role(worker) & not carregando(_) & pedi_bloco(_)
      & espera_bloco(K) & max_espera_bloco(Max) & K >= Max
    <- .abolish(pedi_bloco(_)); .abolish(espera_bloco(_)); !acao_multi(N, Acao).
+!acao_multi(N, Acao)
    : papel_multi(submitter) & role(worker) & not carregando(_) & not pedi_bloco(_)
      & anchor_req(N,AX,AY,AT)
    <- !posicionar_dispenser(AT, AX, AY, Acao).
// Fase C: com a ancora, ir a goal zone, montar e submeter
// (C1) ja conectei com sucesso -> SUBMETE
+!acao_multi(N, submit(N))
    : papel_multi(submitter) & role(worker) & carregando(_) & goalZone(0,0) & flag_submeter
      & lastAction(connect) & lastActionResult(success)
    <- .my_name(Eu); .print("[MULTI] ", Eu, " (sub) SUBMETENDO ", N).
// (C2) na goal zone, helper pronto e bloco dele ja no offset do 2o req -> CONNECT
+!acao_multi(N, connect(Helper, AX, AY))
    : papel_multi(submitter) & role(worker) & carregando(_) & goalZone(0,0)
      & tarefa_multi(N,_,Helper,_,_) & anchor_req(N,AX,AY,_) & segundo_req(N,BX,BY,_)
      & thing(BX,BY,block,_) & pronto_connect(Helper, N)
    <- .my_name(Eu); .print("[MULTI] ", Eu, " (sub) CONNECT ancora(",AX,",",AY,") c/ ", Helper).
// (C3) na goal zone, ainda esperando -> sinaliza pronto e fica parado
+!acao_multi(N, skip)
    : papel_multi(submitter) & role(worker) & carregando(_) & goalZone(0,0)
    <- .my_name(Eu); sinalizar_pronto_connect(Eu, N).
// (C4) navegar ate a goal zone (por visao / mapa)
+!acao_multi(_, Acao)
    : papel_multi(submitter) & role(worker) & carregando(_) & goalzone_visivel(GX,GY)
    <- !mover_rel(GX, GY, Acao).
+!acao_multi(_, Acao)
    : papel_multi(submitter) & role(worker) & carregando(_) & goalzone_conhecida(_,_)
    <- !alvo_goalzone_proximo(TX,TY);  !mover_rumo(TX,TY,Acao).
+!acao_multi(_, Acao) : papel_multi(submitter) & role(worker) & carregando(_) <-
    !explorar(Acao).

/* ====================== HELPER ====================== */
// Fase A: adotar worker
+!acao_multi(_, Acao) : papel_multi(helper) & not role(worker) <- !adotar_worker(Acao).
// Fase B: buscar o SEGUNDO bloco e anexar ao SUL (0,1)
+!acao_multi(N, request(s))
    : papel_multi(helper) & role(worker) & not carregando(_) & not pedi_bloco(_)
      & segundo_req(N,_,_,BT) & thing(0,1,dispenser,DT) & tipo_igual(BT,DT)
    <- +pedi_bloco(s);  +espera_bloco(0);  .abolish(disp_alvo(_,_)).
+!acao_multi(_, attach(s))
    : papel_multi(helper) & role(worker) & not carregando(_) & pedi_bloco(s) & thing(0,1,block,_)
    <- -pedi_bloco(s); .abolish(espera_bloco(_)); .abolish(disp_alvo(_,_)); +carregando(ajuda);
       .my_name(Eu); .print("[MULTI] ", Eu, " (helper) anexou bloco ao sul (0,1)").
+!acao_multi(_, skip)
    : papel_multi(helper) & role(worker) & not carregando(_) & pedi_bloco(_)
      & espera_bloco(K) & max_espera_bloco(Max) & K < Max
    <- Kp = K + 1;  -+espera_bloco(Kp).
+!acao_multi(N, Acao)
    : papel_multi(helper) & role(worker) & not carregando(_) & pedi_bloco(_)
      & espera_bloco(K) & max_espera_bloco(Max) & K >= Max
    <- .abolish(pedi_bloco(_)); .abolish(espera_bloco(_)); !acao_multi(N, Acao).
+!acao_multi(N, Acao)
    : papel_multi(helper) & role(worker) & not carregando(_) & not pedi_bloco(_)
      & segundo_req(N,_,_,BT)
    <- !posicionar_dispenser(BT, 0, 1, Acao).
// Fase C: com o bloco, ir ao alvo (relativo ao submitter), alinhar, connect, detach
// (C1) ja conectei com sucesso -> DETACH (bloco fica preso ao submitter via ancora)
+!acao_multi(_, detach(s))
    : papel_multi(helper) & role(worker) & carregando(_)
      & lastAction(connect) & lastActionResult(success)
    <- .my_name(Eu); .print("[MULTI] ", Eu, " (helper) DETACH apos connect"); -+carregando(detached).
// (C2) no alvo e submitter pronto -> CONNECT meu bloco (0,1) com o submitter
+!acao_multi(N, connect(Sub, 0, 1))
    : papel_multi(helper) & role(worker) & carregando(ajuda)
      & tarefa_multi(N,Sub,_,_,_) & alvo_helper(N,TX,TY) & posicao(X,Y) & X==TX & Y==TY
      & pronto_connect(Sub, N)
    <- .my_name(Eu); .print("[MULTI] ", Eu, " (helper) CONNECT bloco(0,1) c/ ", Sub).
// (C3) no alvo, esperando -> sinaliza pronto e fica parado
+!acao_multi(N, skip)
    : papel_multi(helper) & role(worker) & carregando(ajuda)
      & alvo_helper(N,TX,TY) & posicao(X,Y) & X==TX & Y==TY
    <- .my_name(Eu); sinalizar_pronto_connect(Eu, N).
// (C4) tenho alvo (sei a posicao do submitter) -> navego ate ele
+!acao_multi(N, Acao)
    : papel_multi(helper) & role(worker) & carregando(ajuda) & alvo_helper(N,TX,TY)
    <- !mover_rumo(TX, TY, Acao).
// (C5) sem alvo (sem pos do submitter ainda) -> vou a goal zone / exploro
+!acao_multi(_, Acao)
    : papel_multi(helper) & role(worker) & carregando(_) & goalzone_conhecida(_,_)
    <- !alvo_goalzone_proximo(TX,TY);  !mover_rumo(TX,TY,Acao).
+!acao_multi(_, Acao) : papel_multi(helper) & role(worker) & carregando(_) <-
    !explorar(Acao).

// fallback geral multi: se sou worker e nenhum plano se aplicou, EXPLORA (nao
// trava em skip); so faz skip se nada disso valer.
+!acao_multi(_, Acao) : sou_multi & role(worker) <- !explorar(Acao).
+!acao_multi(_, skip) <- true.

/* ---- DIAGNOSTICO MULTI-BLOCO (gateado por flag_debug) ---- */
+!diag_multi : flag_debug & sou_multi & papel_multi(P) & posicao(X,Y) <-
    .findall(rw, role(worker), Rw);
    .findall(c(C), carregando(C), Carga);
    .findall(pb(D), pedi_bloco(D), PB);
    .findall(a(AX,AY), anchor_req(_,AX,AY,_), Anc);
    .findall(s(BX,BY), segundo_req(_,BX,BY,_), Seg);
    .findall(dav, (anchor_req(_,_,_,AT) & dispenser_visivel(AT,_,_)), DAV);
    .findall(rz, rolezone_conhecida(_,_), RZk);
    .findall(ah(TX,TY), alvo_helper(_,TX,TY), AlvoH);
    .findall(da(AX,AY), disp_alvo(AX,AY), DispAlvo);
    .my_name(Eu);
    .print("[DIAGM] ", Eu, " papel=", P, " pos(",X,",",Y,") worker=", Rw,
           " carrega=", Carga, " pedi=", PB, " disp_alvo=", DispAlvo,
           " anc=", Anc, " seg=", Seg, " disp_anc_vis=", DAV, " alvo_h=", AlvoH).
+!diag_multi <- true.
