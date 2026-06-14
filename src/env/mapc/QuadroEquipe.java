package mapc;

import cartago.Artifact;
import cartago.OPERATION;
import cartago.OpFeedbackParam;
import cartago.ObsProperty;

import java.util.HashMap;
import java.util.HashSet;
import java.util.Map;
import java.util.Set;

/**
 * QuadroEquipe - artefato CArtAgO compartilhado pelo time.
 *
 * <p>Funciona como um "quadro de avisos" centralizado onde os agentes
 * registram informacoes que precisam ser visiveis para todos sem
 * precisar fazer broadcast por mensagens. As propriedades observaveis
 * (definidas com defineObsProperty) viram percepcoes Jason
 * automaticamente nos agentes que executam <code>focus(...)</code>
 * neste artefato.</p>
 *
 * <p>No .jcm declaramos:
 *   <pre>
 *     workspace equipe {
 *         artifact quadro: mapc.QuadroEquipe()
 *     }
 *   </pre>
 * e cada agente tem <code>focus: equipe.quadro</code>, entao todos
 * recebem as observable properties como crencas.</p>
 *
 * <p>Casos de uso pretendidos para evoluir o esqueleto:
 * <ul>
 *   <li>Registrar a tarefa atualmente aceita pelo time:
 *       <code>tarefa_aceita(NomeTask, AgenteResponsavel)</code></li>
 *   <li>Registrar dispensers/goals/taskboards descobertos por exploradores
 *       (ja transformados em coordenadas absolutas merged).</li>
 *   <li>Coordenar leiloes para definir quem vai buscar qual bloco.</li>
 * </ul>
 *
 * <p>Por hora deixamos apenas um contador trivial para servir de
 * SMOKE TEST do CArtAgO durante a montagem do esqueleto. Esse contador
 * pode ser removido quando voce comecar a popular o artefato com dados
 * reais da estrategia.</p>
 *
 * <p>NOTA DIDATICA: separar a coordenacao do time num artefato
 * compartilhado e a forma "JaCaMo-nativa" recomendada por Hubner et al.
 * Isso e o que diferencia uma solucao apenas-Jason (paper [5] LTI-USP)
 * de uma solucao JaCaMo completa - onde o ambiente e cidadao de
 * primeira classe, e nao apenas mensageria entre agentes.</p>
 */
public class QuadroEquipe extends Artifact {

    /*
     * Memoria de deduplicacao do mapa compartilhado.
     *
     * Varios exploradores podem ver o MESMO dispenser/goal/taskboard (em
     * passos diferentes ou ao mesmo tempo) e cada um chama registrar_*.
     * Sem dedup, criariamos observable properties duplicadas. Estes Sets
     * garantem que cada coordenada absoluta entra no quadro UMA unica vez.
     *
     * Chave: "x,y" (ou "x,y,tipo" para dispenser, pois pode haver tipos
     * diferentes na mesma celula em mapas com wrap-around).
     */
    private final Set<String> dispensersVistos  = new HashSet<>();
    private final Set<String> goalsVistas        = new HashSet<>();
    private final Set<String> taskboardsVistos   = new HashSet<>();
    private final Set<String> roleZonesVistas    = new HashSet<>();
    // [Passo 5] dedup dos sinais de pronto-para-connect ("agente|task").
    private final Set<String> prontosConnect     = new HashSet<>();

    /*
     * [Passo 2] Posicao publicada por cada agente (no frame proprio dele).
     * Mantemos a referencia da ObsProperty por agente para atualizar em vez
     * de duplicar. Vira a crenca pos_agente(Nome,X,Y) em todos os focados.
     */
    private final Map<String, ObsProperty> posAgentes = new HashMap<>();

    /**
     * Inicializa as propriedades observaveis do quadro.
     * Chamado automaticamente pelo CArtAgO quando o artefato e instanciado.
     */
    void init() {
        // Contador trivial - prova de vida do artefato.
        // Os agentes verao a crenca: passos_anunciados(0) e isso vai
        // sendo atualizado a cada anunciar_passo chamado.
        defineObsProperty("passos_anunciados", 0);

        // Lugar para a tarefa que o coordenador escolheu trabalhar.
        // Inicialmente "nenhuma". Quando o coordenador chamar
        // anunciar_tarefa(NomeTask) esta property sera atualizada e
        // todos os agentes focados verao +tarefa_atual(NomeTask).
        defineObsProperty("tarefa_atual", "nenhuma");
    }

    /**
     * Operacao chamada por agentes para anunciar que estao em um novo
     * passo (uso didatico - na pratica os agentes usariam +step(_)).
     *
     * Os agentes invocam isso via:
     *   <pre>
     *     anunciar_passo(N).
     *   </pre>
     */
    @OPERATION
    void anunciar_passo(int passo) {
        getObsProperty("passos_anunciados").updateValue(passo);
    }

    /**
     * Operacao usada pelo coordenador para registrar a tarefa que o time
     * vai tentar completar. Os outros agentes vao receber como percepcao
     * e poderao iniciar suas sub-tarefas (buscar bloco, etc).
     */
    @OPERATION
    void anunciar_tarefa(String nomeTask) {
        getObsProperty("tarefa_atual").updateValue(nomeTask);
        // signal e uma forma de disparar um EVENTO Jason (alem da
        // observable property) - util quando outros agentes precisam
        // reagir UMA UNICA VEZ ao anuncio. Comentado por enquanto.
        // signal("nova_tarefa", nomeTask);
    }

    /**
     * [Passo 3] Anuncia a task-ALVO escolhida pelo coordenador, ja decomposta
     * para o caso de UM bloco: nome + (qx,qy) = posicao relativa exigida do
     * bloco + tipo. Vira a crenca tarefa_alvo(Nome,QX,QY,Tipo) nos workers.
     * Idempotente: atualiza se ja existir.
     */
    @OPERATION
    void anunciar_tarefa_alvo(String nome, int qx, int qy, String tipo) {
        if (hasObsProperty("tarefa_alvo")) {
            getObsProperty("tarefa_alvo").updateValues(nome, qx, qy, tipo);
        } else {
            defineObsProperty("tarefa_alvo", nome, qx, qy, tipo);
        }
    }

    /**
     * [Passo 5 - MULTI-BLOCO] Anuncia uma task de 2 blocos com a atribuicao de
     * papeis: quem SUBMETE (submitter) e quem AJUDA (helper), e a goal zone-alvo
     * (coords no frame de referencia) onde a estrutura sera montada e submetida.
     * Vira a crenca tarefa_multi(Nome,Submitter,Helper,GZx,GZy) nos agentes; os
     * offsets/tipos de cada bloco eles leem do proprio percept task(N,...).
     */
    @OPERATION
    void anunciar_tarefa_multi(String nome, String submitter, String helper, int gzx, int gzy) {
        if (hasObsProperty("tarefa_multi")) {
            getObsProperty("tarefa_multi").updateValues(nome, submitter, helper, gzx, gzy);
        } else {
            defineObsProperty("tarefa_multi", nome, submitter, helper, gzx, gzy);
        }
    }

    /**
     * [Passo 5 - BARREIRA] Um worker sinaliza que esta posicionado e pronto para
     * o connect sincronizado da task. Vira pronto_connect(Agente,Task) visivel a
     * todos: o parceiro so dispara connect quando ve o outro pronto (mesmo step).
     * Idempotente por (agente,task).
     */
    @OPERATION
    void sinalizar_pronto_connect(String agente, String task) {
        String chave = agente + "|" + task;
        if (prontosConnect.add(chave)) {
            defineObsProperty("pronto_connect", agente, task);
        }
    }

    /** Limpa o sinal de pronto de um agente (apos connect/desistencia). */
    @OPERATION
    void limpar_pronto_connect(String agente, String task) {
        if (prontosConnect.remove(agente + "|" + task)) {
            removeObsPropertyByTemplate("pronto_connect", agente, task);
        }
    }

    /**
     * Permite consultar a tarefa atual. As vezes e mais conveniente
     * buscar via OPERATION do que via crenca, especialmente em planos
     * que rodam fora do contexto onde a observacao chegou.
     */
    @OPERATION
    void consultar_tarefa(OpFeedbackParam<String> resultado) {
        resultado.set(getObsProperty("tarefa_atual").stringValue());
    }

    /* ================================================================== */
    /* PASSO 1: MAPA COMPARTILHADO DO TIME                                 */
    /* ================================================================== */

    /*
     * Os exploradores convertem suas percepcoes relativas em coordenadas
     * absolutas (origem = posicao inicial de cada um) e publicam aqui o que
     * descobrem. Cada registro vira uma observable property, ou seja, uma
     * crenca em TODOS os agentes que fazem focus: equipe.quadro:
     *
     *   dispenser_descoberto(X, Y, Tipo)
     *   goal_descoberta(X, Y)
     *   taskboard_descoberto(X, Y)
     *
     * ATENCAO (limitacao conhecida, vira TODO do passo 2): cada explorador
     * tem sua PROPRIA origem (0,0), entao as coordenadas que eles publicam
     * so coincidem depois que o time alinhar referenciais via identificacao
     * de companheiros (posicao-espelho). Enquanto o passo 2 nao estiver
     * pronto, trate estas coords como "no referencial de quem descobriu".
     */

    /** Registra um dispenser descoberto (idempotente por coordenada+tipo). */
    @OPERATION
    void registrar_dispenser(int x, int y, String tipo) {
        if (dispensersVistos.add(x + "," + y + "," + tipo)) {
            defineObsProperty("dispenser_descoberto", x, y, tipo);
        }
    }

    /** Registra uma celula de goal zone descoberta (idempotente). */
    @OPERATION
    void registrar_goal(int x, int y) {
        if (goalsVistas.add(x + "," + y)) {
            defineObsProperty("goal_descoberta", x, y);
        }
    }

    /** Registra um taskboard descoberto (idempotente). [nao usado no 2022] */
    @OPERATION
    void registrar_taskboard(int x, int y) {
        if (taskboardsVistos.add(x + "," + y)) {
            defineObsProperty("taskboard_descoberto", x, y);
        }
    }

    /** Registra um role zone descoberto (idempotente). */
    @OPERATION
    void registrar_rolezone(int x, int y) {
        if (roleZonesVistas.add(x + "," + y)) {
            defineObsProperty("rolezone_descoberta", x, y);
        }
    }

    /**
     * [Passo 2] Publica/atualiza a posicao de um agente (no frame proprio).
     * Todos os agentes focados passam a ver pos_agente(Nome,X,Y) como crenca.
     * Base para coordenacao e para o alinhamento de frames (posicao-espelho).
     */
    @OPERATION
    void atualizar_pos_agente(String nome, int x, int y) {
        ObsProperty op = posAgentes.get(nome);
        if (op == null) {
            posAgentes.put(nome, defineObsProperty("pos_agente", nome, x, y));
        } else {
            op.updateValues(nome, x, y);
        }
    }

}
