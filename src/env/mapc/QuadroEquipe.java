package mapc;

import cartago.Artifact;
import cartago.OPERATION;
import cartago.OpFeedbackParam;

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
     * Permite consultar a tarefa atual. As vezes e mais conveniente
     * buscar via OPERATION do que via crenca, especialmente em planos
     * que rodam fora do contexto onde a observacao chegou.
     */
    @OPERATION
    void consultar_tarefa(OpFeedbackParam<String> resultado) {
        resultado.set(getObsProperty("tarefa_atual").stringValue());
    }
}
