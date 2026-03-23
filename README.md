[English Version](#english-version) | [Versão em Português](#versão-em-português)

---

## English Version

# PoE Economy Dashboard

[![Power BI](https://img.shields.io/badge/Power_BI-F2C811?style=for-the-badge&logo=powerbi&logoColor=black)]()
[![PostgreSQL](https://img.shields.io/badge/PostgreSQL-316192?style=for-the-badge&logo=postgresql&logoColor=white)]()
[![DAX](https://img.shields.io/badge/Advanced_DAX-0078D4?style=for-the-badge&logo=microsoft&logoColor=white)]()

## Technical Deep Dive
> **[Click here to read the full Technical Documentation & Logbook (30+ steps of Data Engineering, ETL, and advanced DAX)](TECHNICAL_DOCUMENTATION.md)**

## Project Context
This project consists of the development of an advanced analytical dashboard in Power BI, utilizing PostgreSQL as the backend, for monitoring and analyzing price fluctuations in the Path of Exile game market.

The central objective was to replicate and improve upon the logic of existing community platforms, focusing on solving complex challenges in Data Engineering, dimensional modeling, continuous time intelligence, and the application of advanced business rules via DAX for a corporate-level UI/UX experience and intuitive navigation.

https://github.com/user-attachments/assets/44a7d051-1070-4862-bd52-8a7916c72e8d

## Key Features (What the Dashboard Does)
* **Dynamic Currency Toggle:** Users can instantly switch the entire dashboard's pricing between "Chaos" or "Divine" via a disconnected parameter table and an absolute global currency anchor.
* **League Comparator:** Bypasses Power BI's native drill-through locks, allowing users to plot a second axis and visually compare item inflation across different historical seasons.
* **Trading View Mechanics:** Features 7-day sparkline trends, All-Time High/Low tracking, and a dynamic 3-Day Moving Average toggle to filter out weekend market noise.
* **Smart UI/UX:** Adaptive display that automatically inverts math for micro-transactions (e.g., displaying "1 div = 150 units" instead of "0.006 div"), and self-cleaning slicers that hide empty categories.

## Technologies Used
* **PostgreSQL:** Backend, Dimensional Modeling (Star Schema), Ingestion via Staging Area, Advanced ETL, Window Functions (Deduplication).
* **Power BI:** Data Modeling, Advanced DAX (Time Intelligence, Complex Filter Contexts, Disconnected Parameters), Dynamic UI/UX.

## Data Engineering and Architecture (PostgreSQL)
* **Dimensional Modeling:** Implementation of a classic Star Schema to support cross-analysis of millions of records using **Surrogate Keys** (Integer IDs) to optimize RAM consumption in Power BI's VertiPaq engine.
* **Continuous Time Intelligence:** Creation of a dynamic `dCalendar` dimension using the `generate_series()` function, automatically extracting bounds from active dates to ensure autonomous scalability.
* **Ingestion & Sanitization:** Robust ingestion flow utilizing the **Staging Area** pattern, addressing complex **Schema Drift** from game API changes and implementing deduplication via PostgreSQL's internal physical address (`ctid`).

## Advanced Logic in Power BI (DAX)
* **Complex Filter Contexts:** Global currency anchor using `REMOVEFILTERS` to fetch absolute rates, serving as a universal variable for dynamic price conversion.
* **Normalized Time Intelligence:** Time normalization performed in PostgreSQL (`league_day`), allowing comparative Drill-through charts with a universal X-Axis to visually overlay historical trends.

---

## Versão em Português

# PoE Economy Dashboard

[![Power BI](https://img.shields.io/badge/Power_BI-F2C811?style=for-the-badge&logo=powerbi&logoColor=black)]()
[![PostgreSQL](https://img.shields.io/badge/PostgreSQL-316192?style=for-the-badge&logo=postgresql&logoColor=white)]()
[![DAX](https://img.shields.io/badge/Advanced_DAX-0078D4?style=for-the-badge&logo=microsoft&logoColor=white)]()

## Documentação Técnica Completa
> **[Clique aqui para ler o Diário de Bordo Técnico (Mais de 30 passos detalhando a Engenharia de Dados, ETL e códigos DAX avançados)](TECHNICAL_DOCUMENTATION.md)**

## Contexto do Projeto
Este projeto consiste no desenvolvimento de um dashboard analítico avançado no Power BI, utilizando PostgreSQL como backend, para monitoramento e análise de flutuação de preços no mercado do jogo Path of Exile.

O objetivo central foi replicar e aprimorar a lógica de plataformas existentes na comunidade, focando na resolução de desafios complexos de Engenharia de Dados, modelagem dimensional, integridade de tempo contínua e aplicação de regras de negócio avançadas via DAX para uma experiência de UI/UX de nível corporativo e navegação intuitiva.

https://github.com/user-attachments/assets/a6965ebf-3ecd-4ca5-9bc5-805ee9a9df39

## Principais Funcionalidades (O que o Painel Faz)
* **Conversor de Moeda Dinâmico:** O usuário pode alternar a precificação de todo o painel entre "Chaos" ou "Divine" instantaneamente através de tabelas desconectadas e uma âncora de cotação global.
* **Comparador de Ligas:** Fura o bloqueio nativo de Drill-through do Power BI, permitindo que o usuário plote um segundo eixo Y para comparar a inflação de um item entre temporadas diferentes.
* **Mecânicas de Trading View:** Acompanhamento de tendências em minigráficos de 7 dias, registro de All-Time High/Low, e um botão de Média Móvel de 3 Dias para suavizar ruídos de mercado de fim de semana.
* **UI/UX Inteligente:** Display adaptativo que inverte a matemática para microtransações (exibindo "1 div = 150 unidades" ao invés de "0.006 div"), além de menus laterais autolimpantes que ocultam categorias sem dados.

## Tecnologias Utilizadas
* **PostgreSQL:** Backend, Modelagem Dimensional (Star Schema), Ingestão via Staging Area, ETL avançado, Window Functions (Deduplicação).
* **Power BI:** Modelagem de Dados, DAX Avançado (Inteligência de Tempo, Contextos de Filtro Complexos, Parâmetros Desconectados), UI/UX Dinâmico.

## Engenharia e Arquitetura de Dados (PostgreSQL)
* **Modelagem Dimensional:** Implementação de um Star Schema clássico utilizando **Surrogate Keys** (IDs Numéricos) no lugar de textos para otimizar o consumo de RAM no motor VertiPaq do Power BI e acelerar filtros visuais.
* **Inteligência de Tempo Contínua:** Criação de uma dimensão `dCalendar` dinâmica utilizando a função `generate_series()`, extraindo limites automaticamente para garantir a escalabilidade autônoma.
* **Ingestão e Sanitização:** Fluxo de ingestão robusto utilizando **Staging Area**, resolvendo problemas complexos de **Schema Drift** da API do jogo e deduplicando registros clonados nativamente via endereço físico (`ctid`).

## Lógicas Avançadas no Power BI (DAX)
* **Contextos de Filtro Complexos:** Desenvolvimento de uma âncora de moeda global utilizando `REMOVEFILTERS` para buscar a cotação absoluta servindo como variável universal.
* **Inteligência de Tempo Normalizada:** Normalização temporal calculando a coluna física `league_day`, permitindo gráficos comparativos de Drill-through com Eixo X universal para sobreposição visual precisa.
