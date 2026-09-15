# Geopasto

Aplicativo Android em Flutter para georreferenciamento de propriedades e piquetes, acompanhamento da área destinada à pastagem, localização do usuário no mapa e futura estimativa de massa vegetal com Sentinel-2 e calibração de campo.

## Recursos desta versão

- Cadastro de nome e área total da propriedade, proprietário e telefone.
- Seleção de m², hectare e variações regionais de alqueire.
- Desenho do limite da propriedade e dos piquetes por toque no mapa.
- Levantamento por caminhamento com o GPS do celular.
- Cálculo automático das áreas e do percentual da propriedade destinado à pastagem.
- Posição atual e indicação se o usuário está na propriedade ou em um piquete.
- Mapa com imagem aérea e atribuição do provedor.
- Tela inicial, piquetes, massa vegetal e edição do cadastro.
- Dados mantidos no aparelho.
- Ícone colorido com bovino Nelore pastando.

## Gerar o APK no GitHub

Envie o conteúdo desta pasta para a raiz de um repositório. Abra **Actions**, selecione **Gerar APK Geopasto**, clique em **Run workflow** e, ao terminar, baixe o arquivo **Geopasto-APK** em Artifacts.

## Sentinel-2

A imagem incluída demonstra o visual do produto. A consulta automática de datas, nuvens, NDVI/EVI e biomassa exigirá a conexão da próxima etapa com a API do Copernicus Data Space. A massa vegetal deverá ser calibrada com amostras de campo antes de ser usada para decisão de manejo.
